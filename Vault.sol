pragma solidity ^0.5.16;

import "./common/ExternStateToken.sol";
import "./common/TokenState.sol";
import "./common/MixinResolver.sol";
import "./interfaces/ISynthetic.sol";
import "./interfaces/IVault.sol";

/**
 * @title eUSD ERC20 contract.
 */
contract Vault is ExternStateToken, MixinResolver, IVault {
    // ========== STATE VARIABLES ==========

    string public constant TOKEN_NAME = "EthCash StableCoin";
    string public constant TOKEN_SYMBOL = "eUSD";
    uint8 public constant DECIMALS = 18;

    bytes32 private constant CONTRACT_SYNTHETIC = "Synthetic";
    bytes32 private constant CONTRACT_BLACKHOLE = "Blackhole";
    bytes32 private constant CONTRACT_FEEPOOL = "FeePool";

    function synthetic() internal view returns (ISynthetic) {
        return ISynthetic(resolver.requireAndGetAddress(CONTRACT_SYNTHETIC, "Missing Synthetic address"));
    }

    function blackhole() internal view returns (address) {
        return resolver.requireAndGetAddress(CONTRACT_BLACKHOLE, "Missing Blackhole address");
    }

    function feePool() internal view returns (address) {
        return resolver.requireAndGetAddress(CONTRACT_FEEPOOL, "Missing FeePool address");
    }

    // ========== CONSTRUCTOR ==========

    /**
     * @dev Constructor
     * @param _proxy The main token address of the Proxy contract. This will be ProxyERC20.sol
     * @param _tokenState Address of the external immutable contract containing token balances.
     * @param _owner The owner of this contract.
     * @param _totalSupply On upgrading set to reestablish the current total supply
     * @param _resolver The address of the System Address Resolver
     */
    constructor(address payable _proxy, TokenState _tokenState, address _owner, uint _totalSupply, address _resolver)
        public
        ExternStateToken(_proxy, _tokenState, TOKEN_NAME, TOKEN_SYMBOL, _totalSupply, DECIMALS, _owner)
        MixinResolver(_resolver)
    {}

    // ========== MUTATIVE FUNCTIONS ==========
    /**
     * @notice ERC20 transfer function.
     */
    function transfer(address to, uint value) external optionalProxy returns (bool) {
        require(tokenState.balanceOf(messageSender) >= value, "Not enough eUSD to transfer");
        // Perform the transfer: if there is a problem an exception will be thrown in this call.
        _transfer_byProxy(messageSender, to, value);

        return true;
    }

    /**
     * @notice ERC20 transferFrom function.
     */
    function transferFrom(address from, address to, uint value) external optionalProxy returns (bool) {
        require(tokenState.balanceOf(from) >= value, "Not enough eUSD to transfer");
        // Perform the transfer: if there is a problem,
        // an exception will be thrown in this call.
        return _transferFrom_byProxy(messageSender, from, to, value);
    }

    /**
     * @notice The total eUSD owned by this account.
     */
    function collateral(address account) external view returns (uint) {
        return tokenState.balanceOf(account);
    }

	/**
     * @notice Mints the inflationary eUSD supply. And set amount of balance to the given address.
     * The mint function is callable only by collateral contract.
     */
    function mint(bytes32 currencyKey, address account, uint value, uint fee) external onlyCollateralProxy(currencyKey) returns (uint) {
        require(account != address(0), "Account not set");

        uint totalValue = value.add(fee);
        //Assign amount of value to account.
        tokenState.setBalanceOf(account, tokenState.balanceOf(account).add(value));
        totalSupply = totalSupply.add(totalValue);

        emitTransfer(address(this), account, value);

        if (fee > 0) {
            _transferToFeePool(fee);
        }

        return totalValue;
    }

	/**
     * @notice Burns the avaliable eUSD supply. And set new amount of balance to the given address.
     * The burn function is callable only by collateral proxy contract.
     * Fee is charged and distributed to an escrow contract.
     */
    function burn(bytes32 currencyKey, address account, uint value, uint fee) external onlyCollateralProxy(currencyKey) returns (uint) {
        require(account != address(0), "Account not set");

        uint totalValue = value.add(fee);
		require(totalValue <= tokenState.balanceOf(account), "Not Enough eUSD to burn");

        //Assign amount of value to account.
        tokenState.setBalanceOf(account, tokenState.balanceOf(account).sub(totalValue));
        totalSupply = totalSupply.sub(value);
        emitTransfer(account, address(0), totalValue);

        if (fee > 0) {
            _transferToFeePool(fee);
        }

        return totalValue;
    }

    /**
     * @notice Distributes amount of the burn eUSD fee from FeePool to target address
     */
    function distribute(address account, uint amount) external optionalProxy_onlyOwner returns (uint) {
        require(account != address(0), "Account not set");

        address _feePool = feePool();
        _transfer_byProxy(_feePool, account, amount);
        emitDistributed(account, amount);
        return amount;
    }

    /**
     * @notice Stakes the avaliable eUSD supply. And receives lp amount.
     */
    function stake(uint amount) external optionalProxy {
        require(amount != 0, "Amount should not be 0");
        require(amount <= tokenState.balanceOf(messageSender), "Not Enough eUSD to stake");
        uint staked = synthetic().stake(messageSender, amount);

        _transferToBlackhole(messageSender, amount);
        emitStaked(messageSender, blackhole(), amount, staked);
    }

    /**
     * @notice Burns the avaliable lp amount. And receives eUSD.
     */
    function exit(uint amount) external optionalProxy {
        require(amount != 0, "Amount should not be 0");

        uint received = synthetic().exit(messageSender, amount);
        if (received > 0) {
            _withdrawFromBlackhole(messageSender, received);
            emitExited(blackhole(), messageSender, amount, received);
        }
    }

    /**
     * @notice Stakes the avaliable eUSD supply to fix unbalanceness. And receives scCash.
     */
    function fix(uint amount, uint maxFee) external optionalProxy {
        require(amount != 0, "Amount should not be 0");
        require(amount <= tokenState.balanceOf(messageSender), "Not Enough eUSD to stake");

        uint received = synthetic().fix(messageSender, amount, maxFee);
        if (received > 0) {
            _transferToBlackhole(messageSender, amount);
            emitFixed(messageSender, amount, received);
        }
    }

    /**
     * @notice Exchanges the avaliable lp amount to receives synthetic asset or
     * burns synthetic asset to increase avaliable lp amount.
     */
    function exchange(bytes32 sourceKey, uint amount, bytes32 destKey) external optionalProxy {
        uint received = synthetic().exchange(messageSender, sourceKey, amount, destKey);
        if (received > 0) {
            emitExchange(messageSender, sourceKey, amount, destKey, received);
        }
    }

    function chargeFee(address account, uint fee) external onlySynthetic {
        require(fee <= tokenState.balanceOf(account), "Not Enough eUSD to charge");
        tokenState.setBalanceOf(account, tokenState.balanceOf(account).sub(fee));
        _transferToFeePool(fee);
    }

    function _transferToFeePool(uint fee) internal {
        address _feePool = feePool();
        tokenState.setBalanceOf(_feePool, tokenState.balanceOf(_feePool).add(fee));
        emitTransfer(address(this), _feePool, fee);
    }

    function _transferToBlackhole(address account, uint amount) internal {
        address _blackhole = blackhole();
        _transfer_byProxy(account, _blackhole, amount);
    }

    function _withdrawFromBlackhole(address account, uint amount) internal {
        address _blackhole = blackhole();
        _transfer_byProxy(_blackhole, account, amount);
    }

    // ========== MODIFIERS ==========

    modifier onlyCollateralProxy(bytes32 currencyKey) {
        require(msg.sender == resolver.requireAndGetAddress(currencyKey, "Missing currencyKey address"), "Only authorized collateral contract can perform this action");
        _;
    }

    modifier onlySynthetic{
        require(msg.sender == address(synthetic()), "Missing synthetic address");
        _;
    }

    /* ========== EVENTS ========== */
    event Disributed(address indexed to, uint amount);
    bytes32 internal constant DISTRIBUTED_SIG = keccak256("Disributed(address,uint256)");

    function emitDistributed(address to, uint amount) internal {
        proxy._emit(abi.encode(amount), 2, DISTRIBUTED_SIG, addressToBytes32(to), 0, 0);
    }

    event Staked(address indexed from, address indexed to, uint amount, uint received);
    bytes32 internal constant STAKED_SIG = keccak256("Staked(address,address,uint256,uint256)");

    function emitStaked(address from, address to, uint amount, uint received) internal {
        proxy._emit(abi.encode(amount, received), 3, STAKED_SIG, addressToBytes32(from), addressToBytes32(to), 0);
    }

    event Exited(address indexed from, address indexed to, uint amount, uint received);
    bytes32 internal constant EXITED_SIG = keccak256("Exited(address,address,uint256,uint256)");

    function emitExited(address from, address to, uint amount, uint received) internal {
        proxy._emit(abi.encode(amount, received), 3, EXITED_SIG, addressToBytes32(from), addressToBytes32(to), 0);
    }

    event Fixed(address indexed from, uint amount, uint received);
    bytes32 internal constant FIXED_SIG = keccak256("Fixed(address,uint256,uint256)");

    function emitFixed(address from, uint amount, uint received) internal {
        proxy._emit(abi.encode(amount, received), 2, FIXED_SIG, addressToBytes32(from), 0, 0);
    }

    event Exchange(
        address indexed account,
        bytes32 sourceKey,
        uint256 fromAmount,
        bytes32 destKey,
        uint256 toAmount
    );
    bytes32 internal constant EXCHANGE_SIG = keccak256(
        "Exchange(address,bytes32,uint256,bytes32,uint256)"
    );

    function emitExchange(
        address account,
        bytes32 sourceKey,
        uint256 fromAmount,
        bytes32 destKey,
        uint256 toAmount
    ) internal {
        proxy._emit(
            abi.encode(sourceKey, fromAmount, destKey, toAmount),
            2,
            EXCHANGE_SIG,
            addressToBytes32(account),
            0,
            0
        );
    }
}
