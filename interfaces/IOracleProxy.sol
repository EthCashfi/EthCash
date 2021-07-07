pragma solidity ^0.5.16;

interface IOracleProxy {
    function getDaoAddr() external view returns (address);

    function getOracleInfo(uint256 _ocId) external view returns (address, bool, bytes32);

    function getCoinInfo(uint256 ocId, bytes32 symbol) external view returns (bytes32, int256, uint64, uint64);

    function getCoinInfoById(uint256 ocID, bytes32 symbol, uint64 id) external view returns (bytes32, int256, uint64, uint64);
}