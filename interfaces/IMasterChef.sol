pragma solidity ^0.5.16;

/**
 * @title Collateral Interface
 * @notice Abstract contract to hold public getters
 */
interface IMasterChef {
    function add(bytes32 poolName, address account, uint256 _amount) external;
    function sub(bytes32 poolName, address account, uint256 _amount) external;
    function mintEthC(bytes32 poolName, address _to, uint256 _amount) external;

    function ethCash() external view returns (address);
    function getUserInfo(bytes32 poolName, address _address) external view returns (uint256, uint256, uint256);
    function pendingEthC(bytes32 poolName, address _user) external view returns (uint256);
    function getPoolInfo(bytes32 poolName) external view returns (uint256, uint256, uint256, uint256);
}
