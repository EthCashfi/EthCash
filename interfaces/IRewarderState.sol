pragma solidity ^0.5.16;


/**
 * @title IRewarderState Interface
 * @notice Abstract contract to hold public getters
 */
interface IRewarderState {
    function appendAccountDebtData(address account, uint debt, uint debtEntryIndex, uint currentPeriodStartDebtIndex) external;

    function applicableDebtData(address account, uint closingDebtIndex) external view returns (uint, uint);
}
