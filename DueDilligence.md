># Protocol Due Diligence: ConvexFrax
[ToC]

## ConvexFrax Overview
- [Site](https://frax.convexfinance.com)
- Gov: Governance is split between Convex governance and Frax Governance
- [Docs](https://docs.convexfinance.com/)
- [Audit](https://docs.convexfinance.com/convexfinance/faq/audits): Runs on Convex platform which is previously audited.

General overview of product: https://docs.convexfinance.com/convexfinance/

How Rewards Work:
https://looksrare.org/rewards

## Rug-ability
**Multi-sig:** Yes
    - Looks multisig is https://gnosis-safe.io/app/eth:0xa3C5A1e09150B75ff251c1a7815A07182c3de2FB. Needs 3/5 sigs.
    - Addresses include:
*    c2tp.eth from Convex
*    Sam from Frax
*    Charlie from Curve
*    Winthorpe from Convex
*    Tommy from Votium

    - Multisig owns staking contract.
    - While multisig functions can add pools, update stash factor, or define an arbitrator vault, they cannot in anyway impact existing rewards.
    
**Conclusion:** Multisig cannot in anyway remove previously awarded reward tokens. Nor can they pause any part of the contract that would hold user funds hostage.
    
**Upgradable Contracts:** No
- All contracts for the rewards seem static and would require a migration action from the user.

**Decentralization:**
- The project is run by a decentralized multisig for pool creation
- The token, token distribution and rewards staking contract are solidity contracts, with limited control by owners/admins.
- The protocol itself runs governance but via snapshot voting.

## Audit Reports
[Audit by Mixbyte](https://github.com/mixbytes/audits_public/tree/master/Convex%20Platform)

The platform has been extensively audited, all existing identified problems were resolved, or acknowledged in cases where they had no material impact on the code.

They also have a strong bug bounty program: https://docs.convexfinance.com/convexfinance/faq/bug-bounties

## Strategy Details
### Summary
The `StrategyConvexFraxcvxFXS` strategy updates our existing convex strategy to work with the new `Convex for Frax` it deposits the `cvxFXS/FXS` token into the Convex For Frax depositor.

This contract earns:
 - $FXS rewards from the reward contract paid by Frax.
 - $CVX rewards from the rewards contract paid by Convex.
 - $CRV rewards from the rewards contract paid by Curve.

The strategy sells the CVX and CRV rewards to acquire more FXS, which it uses to enter into the cvxFXS/FXS curve pool token and restake.

### Strategy current APR
Currently the strategy yields 55% per year non-compounded.

### Vault/Strategy Pitfalls
Here are a couple of things which are out of the ordinary and might be of a surprise when reading the code.

#### The Curve pool is not in the registry.
Currently the cvxFXS/FXS pool is not in the Curve registry and so our normal lookup does not work.

#### Added New Functions:
The strategy differs from our current Convex versions as it also now supports functions to declare a `keepCVX` and `keepFXS` amount, in order to be able to support CRV style locking when those are activated for Convex for Frax in the future.


## Path-to-Prod
#### Does Strategy delegate assets?
No

#### Target Prod Vault
Would require a new vault.

#### BaseStrategy Version
0.4.3

#### Target Prod Vault Version
0.4.3

### Testing Plan
Strategy currently passes basic tests.

Current goal is to implement on ApeTax and monitor from there.

#### Ape.tax
##### Will Ape.tax be used?
Yes

##### Will Ape.tax vault be same version # as prod vault?
Yes

##### What conditions are needed to graduate? (e.g. number of harvest cycles, min funds, etc)
 - Be profitable
 - See atleast 7 profitable reward period returns without issue.
 - Ensure slippage is a non-issue with converting funds of at least $100k.

#### Prod Deployment Plan
##### Suggested position in withdrawQueue?
Only cvxFXS/FXS strategy.

##### Does strategy have any deposit/withdraw fees?
No.

##### Suggested debtRatio?
100% only cvxFXS/FXS strategy.

#### Checklist
- [ ] Get additional support from experienced strategist on testing
    - [ ] Run extended tests 
- [ ] Deploy vault version to Ape.tax
- [ ] Deploy a new cvxFXS vault
    - [ ] Add strategy
- [ ] Endorse to prod
