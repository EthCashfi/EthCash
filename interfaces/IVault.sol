pragma solidity ^0.5.16;

/**
 * @title Vault interface contract
 * @notice Abstract contract to hold external getters
 * @dev pseudo interface, actually declared as contract to hold the external getters
 */
interface IVault {
    // ========== external FUNCTIONS ==========

    function collateral(address account) external view returns (uint);

    function transfer(address to, uint value) external returns (bool);

    function transferFrom(address from, address to, uint value) external returns (bool);

    function mint(bytes32 currencyKey, address account, uint value, uint fee) external returns (uint);

    function burn(bytes32 currencyKey, address account, uint value, uint fee) external returns (uint);

    function chargeFee(address account, uint fee) external;
}
