pragma solidity ^0.5.16;


/**
 * @title IRewarder Interface
 * @notice Abstract contract to hold public getters
 */
interface IRewarder {
    function appendAccountDebtData(address account, uint debt, uint debtEntryIndex) external;
}
