pragma solidity ^0.5.16;

import "../common/Owned.sol";
import "../common/ExternStateToken.sol";
import "../common/MixinResolver.sol";
import "../interfaces/IExchanger.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/ISynth.sol";


contract Synth is Owned, IERC20, ExternStateToken, MixinResolver, ISynth {
    /* ========== STATE VARIABLES ========== */

    // Currency key which identifies this Synth to the Synthetix system
    bytes32 public currencyKey;

    uint8 public constant DECIMALS = 18;

    bytes32 private constant CONTRACT_EXCHANGER = "Exchanger";

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address payable _proxy,
        TokenState _tokenState,
        string memory _tokenName,
        string memory _tokenSymbol,
        address _owner,
        bytes32 _currencyKey,
        uint _totalSupply,
        address _resolver
    )
        public
        ExternStateToken(_proxy, _tokenState, _tokenName, _tokenSymbol, _totalSupply, DECIMALS, _owner)
        MixinResolver(_resolver)
    {
        require(_owner != address(0), "_owner cannot be 0");
        require(_proxy != address(0), "_proxy cannot be 0");

        currencyKey = _currencyKey;
    }


    function exchanger() internal view returns (IExchanger) {
        return IExchanger(resolver.requireAndGetAddress(CONTRACT_EXCHANGER, "Missing Exchanger address"));
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function transfer(address to, uint value) public optionalProxy returns (bool) {
        _ensureCanTransfer(messageSender, value);
        // transfers to 0x address will be burned
        if (to == address(0)) {
            return _internalBurn(messageSender, value);
        }

        return super._internalTransfer(messageSender, to, value);
    }

    function transferFrom(address from, address to, uint value) public optionalProxy returns (bool) {
        return _internalTransferFrom(from, to, value);
    }

    // Allow synthetix to issue a certain number of synths from an account.
    // forward call to _internalIssue
    function issue(address account, uint amount) external onlyExchanger {
        _internalIssue(account, amount);
    }

    // Allow synthetix or another synth contract to burn a certain number of synths from an account.
    // forward call to _internalBurn
    function burn(address account, uint amount) external onlyExchanger {
        _internalBurn(account, amount);
    }

    function _internalIssue(address account, uint amount) internal {
        tokenState.setBalanceOf(account, tokenState.balanceOf(account).add(amount));
        totalSupply = totalSupply.add(amount);
        emitTransfer(address(0), account, amount);
        emitIssued(account, amount);
    }

    function _internalBurn(address account, uint amount) internal returns (bool) {
        _ensureCanTransfer(account, amount);

        tokenState.setBalanceOf(account, tokenState.balanceOf(account).sub(amount));
        totalSupply = totalSupply.sub(amount);
        emitTransfer(account, address(0), amount);
        emitBurned(account, amount);

        return true;
    }

    // Allow owner to set the total supply on import.
    function setTotalSupply(uint amount) external optionalProxy_onlyOwner {
        totalSupply = amount;
    }

    /* ========== VIEWS ========== */
    function _ensureCanTransfer(address from, uint value) internal view {
        require(tokenState.balanceOf(from) >= value, "Not enough amount to transfer");
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _internalTransferFrom(address from, address to, uint value) internal returns (bool) {
        _ensureCanTransfer(messageSender, value);
        // Skip allowance update in case of infinite allowance
        if (tokenState.allowance(from, messageSender) != uint(-1)) {
            // Reduce the allowance by the amount we're transferring.
            // The safeSub call will handle an insufficient allowance.
            tokenState.setAllowance(from, messageSender, tokenState.allowance(from, messageSender).sub(value));
        }

        return super._internalTransfer(from, to, value);
    }

    /* ========== MODIFIERS ========== */

    modifier onlyExchanger() {
        require(msg.sender == address(exchanger()),  "Only Exchanger contract allowed");
        _;
    }

    /* ========== EVENTS ========== */
    event Issued(address indexed account, uint value);
    bytes32 private constant ISSUED_SIG = keccak256("Issued(address,uint256)");

    function emitIssued(address account, uint value) internal {
        proxy._emit(abi.encode(value), 2, ISSUED_SIG, addressToBytes32(account), 0, 0);
    }

    event Burned(address indexed account, uint value);
    bytes32 private constant BURNED_SIG = keccak256("Burned(address,uint256)");

    function emitBurned(address account, uint value) internal {
        proxy._emit(abi.encode(value), 2, BURNED_SIG, addressToBytes32(account), 0, 0);
    }
}
