// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./interfaces/ITradeFactory.sol";
import "./interfaces/curve.sol";
import "./interfaces/uniswap.sol";
import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
    function basefee_global() external view returns (uint256);
}

interface HealthCheck {
    function check(
        uint256 profit,
        uint256 loss,
        uint256 debtPayment,
        uint256 debtOutstanding,
        uint256 totalDebt
    ) external view returns (bool);
}

interface IUniV3 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

interface IConvexRewards {
    // strategy's staked balance in the synthetix staking contract
    function balanceOf(address account) external view returns (uint256);

    // read how much claimable CRV a strategy has
    function earned(address account) external view returns (uint256);

    // stake a convex tokenized deposit
    function stake(uint256 _amount) external returns (bool);

    // withdraw to a convex tokenized deposit, probably never need to use this
    function withdraw(uint256 _amount, bool _claim) external returns (bool);

    // withdraw directly to curve LP token, this is what we primarily use
    function withdrawAndUnwrap(uint256 _amount, bool _claim)
        external
        returns (bool);

    // claim rewards, with an option to claim extra rewards or not
    function getReward(address _account, bool _claimExtras)
        external
        returns (bool);

    // check if we have rewards on a pool
    function extraRewardsLength() external view returns (uint256);

    // if we have rewards, see what the address is
    function extraRewards(uint256 _reward) external view returns (address);

    // read our rewards token
    function rewardToken() external view returns (address);

    // check our reward period finish
    function periodFinish() external view returns (uint256);
}

interface IConvexDeposit {
    // deposit into convex, receive a tokenized deposit.  parameter to stake immediately (we always do this).
    function deposit(
        uint256 _pid,
        uint256 _amount,
        bool _stake
    ) external returns (bool);

    // burn a tokenized deposit (Convex deposit tokens) to receive curve lp tokens back
    function withdraw(uint256 _pid, uint256 _amount) external returns (bool);

    // give us info about a pool based on its pid
    function poolInfo(uint256)
        external
        view
        returns (
            address,
            address,
            address,
            address,
            address,
            bool
        );
}

// Part: IOracle

interface IOracle {
    function ethToAsset(
        uint256 _ethAmountIn,
        address _tokenOut,
        uint32 _twapPeriod
    ) external view returns (uint256 amountOut);
}

// Part: StrategyConvexBase

abstract contract StrategyConvexBase is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */
    // these should stay the same across different wants.
    address public tradeFactory = address(0);

    // convex stuff
    address public constant depositContract =
        0xF403C135812408BFbE8713b5A23a04b3D48AAE31; // this is the deposit contract that all pools use, aka booster
    address public rewardsContract; // This is unique to each curve pool
    uint256 public pid; // this is unique to each pool //72

    // keepCRV stuff
    uint256 public keepCRV; // the percentage of CRV we re-lock for boost (in basis points)
    uint256 public keepFXS; // the percentage of FXS we relock (if any) in basis points for when FXS adds future staking multiplier.
    uint256 public keepCVX; // the percentage of CVX we lock (if any) in basis points to provide upgradability of this contract working with future CVX vote locking.
    address public constant voter = 0xF147b8125d2ef93FB6965Db97D6746952a133934; // Yearn's veCRV voter, we send some extra CRV here
    address public fxsVoter; // an unset voter location that must be set prior to setting a holding fee in FXS
    address public cvxVoter; // an unset voter location that must be set prior to setting a holding fee in CVX
    address public extraRewardsFXSContract = 0x28120D9D49dBAeb5E34D6B809b842684C482EF27;
    uint256 internal constant FEE_DENOMINATOR = 10000; // this means all of our fee values are in bips
    uint256 internal constant maxBasis = 10000;
    IConvexRewards public IRewardsContract = IConvexRewards(rewardsContract);
    IConvexDeposit public IDepositContract = IConvexDeposit(depositContract);
    IConvexRewards public IFraxRewardsContract = IConvexRewards(extraRewardsFXSContract);


    // Swap stuff
    address internal constant sushiswap =
        0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F; // default to sushiswap, more CRV and CVX liquidity there

    IERC20 internal constant crv =
        IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 internal constant cvx =
        IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 internal constant weth =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 internal constant fxs =
        IERC20(0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0);

    // keeper stuff
    uint256 public harvestProfitNeeded; // we use this to set our dollar target (in USDT) for harvest sells
    bool internal forceHarvestTriggerOnce; // only set this to true when we want to trigger our keepers to harvest for us

    string internal stratName; // we use this to be able to adjust our strategy's name

    // convex-specific variables
    bool public claimRewards; // boolean if we should always claim rewards when withdrawing, usually withdrawAndUnwrap (generally this should be false)

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault) public BaseStrategy(_vault) {}

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    function stakedBalance() public view returns (uint256) {
        // how much want we have staked in Convex
        return IRewardsContract.balanceOf(address(this));
    }

    function balanceOfWant() public view returns (uint256) {
        // balance of want sitting in our strategy
        return want.balanceOf(address(this));
    }

    function claimableBalance() public view returns (uint256) {
        // how much CRV we can claim from the staking contract
        return IRewardsContract.earned(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(stakedBalance());
    }

    /* ========== CONSTANT FUNCTIONS ========== */
    // these should stay the same across different wants.

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        // Send all of our Curve pool tokens to be deposited
        uint256 _toInvest = balanceOfWant();
        // deposit into convex and stake immediately but only if we have something to invest
        if (_toInvest > 0) {
            IDepositContract.deposit(pid, _toInvest, true);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _wantBal = balanceOfWant();
        if (_amountNeeded > _wantBal) {
            uint256 _stakedBal = stakedBalance();
            if (_stakedBal > 0) {
                IRewardsContract.withdrawAndUnwrap(
                    Math.min(_stakedBal, _amountNeeded.sub(_wantBal)),
                    claimRewards
                );
            }
            uint256 _withdrawnBal = balanceOfWant();
            _liquidatedAmount = Math.min(_amountNeeded, _withdrawnBal);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            // we have enough balance to cover the liquidation available
            return (_amountNeeded, 0);
        }
    }

    // fire sale, get rid of it all!
    function liquidateAllPositions() internal override returns (uint256) {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            // don't bother withdrawing zero
            IRewardsContract.withdrawAndUnwrap(
                _stakedBal,
                claimRewards
            );
        }
        return balanceOfWant();
    }

    // in case we need to exit into the convex deposit token, this will allow us to do that
    // make sure to check claimRewards before this step if needed
    // plan to have gov sweep convex deposit tokens from strategy after this
    function withdrawToConvexDepositTokens() external onlyAuthorized {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            IRewardsContract.withdraw(_stakedBal, claimRewards);
        }
    }

    // we don't want for these tokens to be swept out. We allow gov to sweep out cvx vault tokens; we would only be holding these if things were really, really rekt.
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        return new address[](0);
    }

    /* ========== SETTERS ========== */

    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    // Set the amount of CRV to be locked in Yearn's veCRV voter from each harvest. Default is 10%.
    function setKeepCRV(uint256 _keepCRV) external onlyAuthorized {
        require(_keepCRV <= 10_000);
        keepCRV = _keepCRV;
    }

    //Allow setting of the FXS keep amount, but ensure that an FXS Voter contract of some type has first been set.
    function setKeepFXS(uint256 _keepFXS) external onlyAuthorized {
        require(fxsVoter != address(0));
        require(_keepFXS <= 10_000);
        keepFXS = _keepFXS;
    }

    //Allow setting of the FXS keep amount, but ensure that an FXS Voter contract of some type has first been set.
    function setKeepCVX(uint256 _keepCVX) external onlyAuthorized {
        require(cvxVoter != address(0));
        require(_keepCVX <= 10_000);
        keepCVX = _keepCVX;
    }

    //Allow authorized to set the fxsVoter but require it is a contract.
    function setFXSVoter(address _fxsVoter) external onlyAuthorized {
        require(address(_fxsVoter).isContract());
        fxsVoter = _fxsVoter;
    }

    //Allow authorized to set the fxsVoter but require it is a contract.
    function setCVXVoter(address _cvxVoter) external onlyAuthorized {
        require(address(_cvxVoter).isContract());
        cvxVoter = _cvxVoter;
    }

    // We usually don't need to claim rewards on withdrawals, but might change our mind for migrations etc
    function setClaimRewards(bool _claimRewards) external onlyAuthorized {
        claimRewards = _claimRewards;
    }

    // This determines when we tell our keepers to harvest based on profit. this is how much in USDT we need to make. remember, 6 decimals!
    function setHarvestProfitNeeded(uint256 _harvestProfitNeeded)
        external
        onlyAuthorized
    {
        harvestProfitNeeded = _harvestProfitNeeded;
    }

    // This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyAuthorized
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }
}

contract StrategyConvexFraxcvxFXS is StrategyConvexBase {
    /* ========== STATE VARIABLES ========== */
    // these will likely change across different wants.
    uint256 private constant max = type(uint256).max;
    ICurveFi public curve; // Curve Pool, need this for buying more pool tokens
    uint256 public maxGasPrice; // this is the max gas price we want our keepers to pay for harvests/tends in gwei
    address public constant strategistMultisig = address(0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7);
    
    // Uniswap stuff
    IOracle internal constant oracle =
        IOracle(0x0F1f5A87f99f0918e6C81F16E59F3518698221Ff); // this is only needed for strats that use uniV3 for swaps
    address internal constant uniswapv3 =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant uniswapv2 =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    IERC20 internal constant usdt =
        IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);


    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        uint256 _pid,
        address _curvePool,
        string memory _name
    ) public StrategyConvexBase(_vault) {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 7 days; // 7 days in seconds, if we hit this then harvestTrigger = True
        debtThreshold = 1 * 1e6; // we shouldn't ever have debt, but set a bit of a buffer
        profitFactor = 1_000_000; // in this strategy, profitFactor is only used for telling keep3rs when to move funds from vault to strategy
        harvestProfitNeeded = 80_000 * 1e6; // this is how much in USDT we need to make. remember, 6 decimals!
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012; // health.ychad.eth

        // want = Curve LP
        want.approve(address(depositContract), type(uint256).max);

        // set our keepCRV
        keepCRV = 1000;

        // this is the pool specific to this vault, used for depositing
        curve = ICurveFi(_curvePool);

        //FXS token approval for depositing into curve pool
        fxs.approve(address(curve), type(uint256).max);

        // setup our rewards contract
        pid = _pid; // this is the pool ID on convex, we use this to determine what the reweardsContract address is
        address lptoken;
        (lptoken, , , rewardsContract, , ) = IDepositContract
            .poolInfo(_pid);

        // check that our LP token based on our pid matches our want
        require(address(lptoken) == address(want));

        // set our strategy's name
        stratName = _name;

        // these are our approvals and path specific to this contract


        // set our max gas price
        maxGasPrice = 100 * 1e9;
    }

event existingCrvBalanceEvent(uint256 _existingCrvBalanceEvent);
event existingCvxBalanceEvent(uint256 _existingCvxBalanceEvent);
event existingFxsBalanceEvent(uint256 _existingFxsBalanceEvent);
event claimableBalanceEvent(uint256 _claimableBalanceEvent);
    /* ========== VARIABLE FUNCTIONS ========== */
    // these will likely change across different wants.

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        //snapshot existing balances so we only transfer voting reserve on new tokens
        uint256 existingCrvBalance = crv.balanceOf(address(this));
        uint256 existingConvexBalance = cvx.balanceOf(address(this));
        uint256 existingFxsBalance = fxs.balanceOf(address(this));
        emit existingCrvBalanceEvent(existingCrvBalance);
        emit existingCvxBalanceEvent(existingConvexBalance);
        emit existingFxsBalanceEvent(existingFxsBalance);

        uint256 claimableBalanceBeforeIf = claimableBalance();
        emit claimableBalanceEvent(claimableBalanceBeforeIf);
        // if we have anything staked, then harvest CRV and CVX from the rewards contract
        if (claimableBalance() > 0) {
            // this claims our CRV, CVX, and any extra tokens like SNX or ANKR. set to false if these tokens don't exist, true if they do.
            IRewardsContract.getReward(address(this), true);

            uint256 crvBalance = crv.balanceOf(address(this));
            uint256 convexBalance = cvx.balanceOf(address(this));
            uint256 fxsBalance = fxs.balanceOf(address(this));

            //Send CRV to voter
            uint256 _sendToVoterCRV = 0;
            if(crvBalance > existingCrvBalance){
                uint256 crvGrowthBalance = crvBalance.sub(existingCrvBalance);
                _sendToVoterCRV = crvGrowthBalance.mul(keepCRV).div(FEE_DENOMINATOR);
                if (_sendToVoterCRV > 0) {
                    crv.safeTransfer(strategistMultisig, _sendToVoterCRV);
                }
            }

            //Send FXS to voter
            if(keepFXS > 0){
                uint256 _sendToVoterFXS = 0;
                if(fxsBalance > existingFxsBalance){
                    uint256 fxsGrowthBalance = fxsBalance.sub(existingFxsBalance);
                    _sendToVoterFXS = fxsGrowthBalance.mul(keepFXS).div(FEE_DENOMINATOR);
                    if (_sendToVoterFXS > 0) {
                        fxs.safeTransfer(strategistMultisig, _sendToVoterFXS);
                    }
                }
            }

            //Send CVX to voter
            if(keepCVX > 0){
                uint256 _sendToVoterCVX = 0;
                if(convexBalance > existingConvexBalance){
                    uint256 cvxGrowthBalance = convexBalance.sub(existingConvexBalance);
                    _sendToVoterCVX = cvxGrowthBalance.mul(keepCVX).div(FEE_DENOMINATOR);
                    if (_sendToVoterCVX > 0) {
                        cvx.safeTransfer(strategistMultisig, _sendToVoterCVX);
                    }
                }
            }

            // deposit our FXS to Curve if we have any
            fxsBalance = fxs.balanceOf(address(this));
            if (fxsBalance > 0) {
                curve.add_liquidity([0, fxsBalance], 0);
            }
        }

        // debtOustanding will only be > 0 in the event of revoking or if we need to rebalance from a withdrawal or lowering the debtRatio
        if (_debtOutstanding > 0) {
            uint256 _stakedBal = stakedBalance();
            if (_stakedBal > 0) {
                IRewardsContract.withdrawAndUnwrap(
                    Math.min(_stakedBal, _debtOutstanding),
                    claimRewards
                );
            }
            uint256 _withdrawnBal = balanceOfWant();
            _debtPayment = Math.min(_debtOutstanding, _withdrawnBal);
        }

        // serious loss should never happen, but if it does (for instance, if Curve is hacked), let's record it accurately
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        // if assets are greater than debt, things are working great!
        if (assets > debt) {
            _profit = assets.sub(debt);
            uint256 _wantBal = balanceOfWant();
            if (_profit.add(_debtPayment) > _wantBal) {
                // this should only be hit following donations to strategy
                liquidateAllPositions();
            }
        }
        // if assets are less than debt, we are in trouble
        else {
            _loss = debt.sub(assets);
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    // migrate our want token to a new strategy if needed, make sure to check claimRewards first
    // also send over any CRV or CVX that is claimed; for migrations we definitely want to claim
    function prepareMigration(address _newStrategy) internal override {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            IRewardsContract.withdrawAndUnwrap(
                _stakedBal,
                claimRewards
            );
        }
        crv.safeTransfer(_newStrategy, crv.balanceOf(address(this)));
        cvx.safeTransfer(
            _newStrategy,
            cvx.balanceOf(address(this))
        );
        fxs.safeTransfer(_newStrategy, fxs.balanceOf(address(this)));
    }

    /* ========== KEEP3RS ========== */

    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // trigger if we want to manually harvest
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest if we have a profit to claim
        if (claimableProfitInUsdt() > harvestProfitNeeded) {
            return true;
        }

        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        // check if the base fee gas price is higher than we allow
        if (readBaseFee() > maxGasPrice) {
            return false;
        }

        return super.harvestTrigger(callCostinEth);
    }

    function readBaseFee() internal view returns (uint256 baseFee) {
        IBaseFee _baseFeeOracle =
            IBaseFee(0xf8d0Ec04e94296773cE20eFbeeA82e76220cD549);
        return _baseFeeOracle.basefee_global();
    }

    
    // we will need to add rewards token here if we have them
    function claimableProfitInUsdt() internal view returns (uint256) {
        // calculations pulled directly from CVX's contract for minting CVX per CRV claimed
        uint256 totalCliffs = 1_000;
        uint256 maxSupply = 100 * 1_000_000 * 1e18; // 100mil
        uint256 reductionPerCliff = 100_000 * 1e18; // 100,000
        uint256 supply = cvx.totalSupply();
        uint256 mintableCvx;

        uint256 cliff = supply.div(reductionPerCliff);
        uint256 _claimableBal = claimableBalance();
        uint256 extraRewardsFXS = IFraxRewardsContract.earned(address(this));
        //mint if below total cliffs
        if (cliff < totalCliffs) {
            //for reduction% take inverse of current cliff
            uint256 reduction = totalCliffs.sub(cliff);
            //reduce
            mintableCvx = _claimableBal.mul(reduction).div(totalCliffs);

            //supply cap check
            uint256 amtTillMax = maxSupply.sub(supply);
            if (mintableCvx > amtTillMax) {
                mintableCvx = amtTillMax;
            }
        }

        address[] memory crv_usd_path = new address[](3);
        crv_usd_path[0] = address(crv);
        crv_usd_path[1] = address(weth);
        crv_usd_path[2] = address(usdt);

        address[] memory cvx_usd_path = new address[](3);
        cvx_usd_path[0] = address(cvx);
        cvx_usd_path[1] = address(weth);
        cvx_usd_path[2] = address(usdt);

        address[] memory fxs_usd_path = new address[](3);
        fxs_usd_path[0] = address(fxs);
        fxs_usd_path[1] = address(weth);
        fxs_usd_path[2] = address(usdt);

        uint256 crvValue;
        if (_claimableBal > 0) {
            uint256[] memory crvSwap =
                IUniswapV2Router02(sushiswap).getAmountsOut(
                    _claimableBal,
                    crv_usd_path
                );
            crvValue = crvSwap[crvSwap.length - 1];
        }

        uint256 cvxValue;
        if (mintableCvx > 0) {
            uint256[] memory cvxSwap =
                IUniswapV2Router02(sushiswap).getAmountsOut(
                    mintableCvx,
                    cvx_usd_path
                );
            cvxValue = cvxSwap[cvxSwap.length - 1];
        }

        uint256 fxsValue;
        if(extraRewardsFXS > 0){
            uint256[] memory fxsSwap =
                IUniswapV2Router02(sushiswap).getAmountsOut(
                    extraRewardsFXS,
                    fxs_usd_path
                );
            fxsValue = fxsSwap[fxsSwap.length - 1];
        }
        uint profit = crvValue.add(cvxValue).add(fxsValue);
        
        return profit;
    }

    // convert our keeper's eth cost into want
    function ethToWant(uint256 _ethAmount)
        public
        view
        override
        returns (uint256)
    {
        uint256 callCostInWant;
        if (_ethAmount > 0) {
            address fxsCall = address(fxs);
            uint256 callCostInFXS =
                oracle.ethToAsset(_ethAmount, fxsCall, 1800);
            callCostInWant = curve.calc_token_amount([0, callCostInFXS], true);
        }
        return callCostInWant;
    }

    /* ========== SETTERS ========== */

    // set the maximum gas price we want to pay for a harvest/tend in gwei
    function setGasPrice(uint256 _maxGasPrice) external onlyAuthorized {
        maxGasPrice = _maxGasPrice.mul(1e9);
    }

    // ----------------- YSWAPS FUNCTIONS ---------------------

    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        // approve and set up trade factory
        crv.safeApprove(_tradeFactory, max);
        cvx.safeApprove(_tradeFactory, max);
        fxs.safeApprove(_tradeFactory, max);
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        tf.enable(address(crv), address(want));
        tf.enable(address(cvx), address(want));
        tf.enable(address(fxs), address(want));
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        crv.safeApprove(tradeFactory, 0);
        cvx.safeApprove(tradeFactory, 0);
        fxs.safeApprove(tradeFactory, 0);
        tradeFactory = address(0);
    }
}