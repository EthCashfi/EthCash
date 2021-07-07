pragma solidity ^0.5.16;

// Inheritance
import "./common/Owned.sol";
import "./interfaces/ISystemStatus.sol";

contract SystemStatus is Owned, ISystemStatus {
    bytes32 public constant SECTION_SYSTEM = "System";
    bytes32 public constant SECTION_SYNTHETIC = "Synthetic";
    bytes32 public constant SECTION_EXCHANGE = "Exchange";

    bool public systemSuspension;

    bool public syntheticSuspension;

    bool public exchangeSuspension;

    //collateral suspension status
    mapping(bytes32 => bool) public collateralSuspensions;

    //synth suspension status
    mapping(bytes32 => bool) public synthSuspensions;

    constructor(address _owner, bool suspension) public Owned(_owner) {
        systemSuspension = suspension;
        syntheticSuspension = suspension;
        exchangeSuspension = suspension;
    }

    /* ========== VIEWS ========== */
    function requireSystemActive() external view {
        _internalRequireSystemActive();
    }

    function requireSyntheticActive() external view {
        _internalRequireSystemActive();
        require(!syntheticSuspension, "Synthetic is suspended. Operation prohibited");
    }

    function requireExchangeActive() external view {
        _internalRequireSystemActive();
        require(!exchangeSuspension, "Exchange is suspended. Operation prohibited");
    }

    function requireCollateralActive(bytes32 currencyKey) external view {
        // Collateral operations requires the system be active
        _internalRequireSystemActive();
        require(!collateralSuspensions[currencyKey], "Collateral is suspended. Operation prohibited");
    }

    function requireSynthActive(bytes32 currencyKey) external view {
        // Collateral operations requires the system be active
        _internalRequireSystemActive();
        require(!synthSuspensions[currencyKey], "Synth is suspended. Operation prohibited");
    }

    function getCollateralSuspensions(bytes32[] calldata collaterals)
        external
        view
        returns (bool[] memory suspensions)
    {
        suspensions = new bool[](collaterals.length);

        for (uint i = 0; i < collaterals.length; i++) {
            suspensions[i] = collateralSuspensions[collaterals[i]];
        }
    }

    function getSynthSuspensions(bytes32[] calldata synths)
        external
        view
        returns (bool[] memory suspensions)
    {
        suspensions = new bool[](synths.length);

        for (uint i = 0; i < synths.length; i++) {
            suspensions[i] = synthSuspensions[synths[i]];
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function suspendSystem() external onlyOwner {
        systemSuspension = true;
        emit StatusChanged(SECTION_SYSTEM, true);
    }

    function resumeSystem() external onlyOwner {
        systemSuspension = false;
        emit StatusChanged(SECTION_SYSTEM, false);
    }

    function suspendSynthetic() external onlyOwner {
        syntheticSuspension = true;
        emit StatusChanged(SECTION_SYNTHETIC, true);
    }

    function resumeSynthetic() external onlyOwner {
        syntheticSuspension = false;
        emit StatusChanged(SECTION_SYNTHETIC, false);
    }

    function suspendExchange() external onlyOwner {
        exchangeSuspension = true;
        emit StatusChanged(SECTION_EXCHANGE, true);
    }

    function resumeExchange() external onlyOwner {
        exchangeSuspension = false;
        emit StatusChanged(SECTION_EXCHANGE, false);
    }

    function suspendCollateral(bytes32 currencyKey) external onlyOwner {
        collateralSuspensions[currencyKey] = true;
        emit CollateralStatusChanged(currencyKey, true);
    }

    function resumeCollateral(bytes32 currencyKey) external onlyOwner {
        collateralSuspensions[currencyKey] = false;
        emit CollateralStatusChanged(currencyKey, false);
    }

    function suspendSynth(bytes32 currencyKey) external onlyOwner {
        synthSuspensions[currencyKey] = true;
        emit SynthStatusChanged(currencyKey, true);
    }

    function resumeSynth(bytes32 currencyKey) external onlyOwner {
        synthSuspensions[currencyKey] = false;
        emit SynthStatusChanged(currencyKey, false);
    }

    /* ========== INTERNAL FUNCTIONS ========== */
    function _internalRequireSystemActive() internal view {
        require(!systemSuspension, "System is suspended, Operation prohibited");
    }

    /* ========== EVENTS ========== */

    event StatusChanged(bytes32 key, bool suspension);

    event CollateralStatusChanged(bytes32 key, bool suspension);

    event SynthStatusChanged(bytes32 key, bool suspension);
}
