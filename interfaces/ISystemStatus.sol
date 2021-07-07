pragma solidity ^0.5.16;


interface ISystemStatus {
    // Views
    function requireSystemActive() external view;

    function requireSyntheticActive() external view;

    function requireExchangeActive() external view;

    function requireCollateralActive(bytes32 currencyKey) external view;

    function requireSynthActive(bytes32 currencyKey) external view;
}
