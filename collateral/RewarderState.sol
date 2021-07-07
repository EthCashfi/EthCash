/*
custom rewarder state
*/

pragma solidity ^0.5.16;

import "../common/Owned.sol";
import "../common/State.sol";
import "../interfaces/IRewarderState.sol";
import "openzeppelin-solidity-2.3.0/contracts/math/SafeMath.sol";

contract RewarderState is Owned, State, IRewarderState {
    /* ========== STATE VARIABLES ========== */

    using SafeMath for uint;

    uint8 public constant REWARD_PERIOD_LENGTH = 2;

    // A struct for handing debt associated
    // with an individual user's debt position
    // Debt position store global debt value
    struct DebtData {
        uint debt;
        uint debtEntryIndex;
    }
    // The DebtData activity that's happened in a fee period.
    mapping(address => DebtData[REWARD_PERIOD_LENGTH]) public accountLedger;

    constructor(address _owner, address _associatedContract) public Owned(_owner) State(_associatedContract) {
        require(_owner != address(0), "_owner can not be zero");
    }

    function getAccountsDebtEntry(address account, uint index)
        public
        view
        returns (uint debt, uint debtEntryIndex)
    {
        require(index < REWARD_PERIOD_LENGTH, "Index exceeds the REWARD_PERIOD_LENGTH");

        debt = accountLedger[account][index].debt;
        debtEntryIndex = accountLedger[account][index].debtEntryIndex;
    }

    function applicableDebtData(address account, uint closingDebtIndex) external view returns (uint, uint) {
        DebtData[REWARD_PERIOD_LENGTH] memory debtData = accountLedger[account];

        for (uint i = 0; i < REWARD_PERIOD_LENGTH; i++) {
            if (closingDebtIndex >= debtData[i].debtEntryIndex) {
                return (debtData[i].debt, debtData[i].debtEntryIndex);
            }
        }
    }

    function appendAccountDebtData(
        address account,
        uint debt,
        uint debtEntryIndex,
        uint currentPeriodStartDebtIndex
    ) external onlyAssociatedContract {
        // Is the current debtEntryIndex within this fee period
        if (accountLedger[account][0].debtEntryIndex < currentPeriodStartDebtIndex) {
            debtDataIndexOrder(account);
        }

        // Always store the latest DebtData entry at [0]
        accountLedger[account][0].debt = debt;
        accountLedger[account][0].debtEntryIndex = debtEntryIndex;
    }


    function debtDataIndexOrder(address account) private {
        for (uint i = REWARD_PERIOD_LENGTH - 2; i < REWARD_PERIOD_LENGTH; i--) {
            uint next = i + 1;
            accountLedger[account][next].debt = accountLedger[account][i].debt;
            accountLedger[account][next].debtEntryIndex = accountLedger[account][i].debtEntryIndex;
        }
    }
}
