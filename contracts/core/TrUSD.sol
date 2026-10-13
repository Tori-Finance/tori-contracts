// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title TrUSD
 * @notice trUSD stablecoin
 */
contract TrUSD is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    ERC20BurnableUpgradeable,
    ERC20PermitUpgradeable,
    UUPSUpgradeable
{
    /// @notice Role for timelock-protected operations (setMinter, upgradeTo)
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    address public minter;
    bool private _timelockAdminInitialized;

    event MinterUpdated(address indexed oldMinter, address indexed newMinter);
    event TimelockAdminUpdated(address indexed oldTimelockAdmin, address indexed newTimelockAdmin);

    error ZeroAddressException();
    error OnlyMinter();
    error CantRenounceOwnership();
    error UseSetTimelockAdmin();
    error TimelockAdminAlreadyInitialized();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param admin Initial owner address
     */
    function initialize(address admin) public initializer {
        if (admin == address(0)) revert ZeroAddressException();

        __AccessControlDefaultAdminRules_init(1 days, admin);
        __ERC20_init("trUSD", "trUSD");
        __ERC20Burnable_init();
        __ERC20Permit_init("trUSD");
        __UUPSUpgradeable_init();

        _setRoleAdmin(TIMELOCK_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
    }

    function setMinter(address newMinter) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        emit MinterUpdated(minter, newMinter);
        minter = newMinter;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert OnlyMinter();
        _mint(to, amount);
    }

    function renounceRole(bytes32, address) public virtual override {
        revert CantRenounceOwnership();
    }

    /**
     * @notice Initialize the timelock admin - can only be called once by DEFAULT_ADMIN
     * @param timelockAdmin Address of the timelock contract
     * @dev This bootstraps the TIMELOCK_ADMIN_ROLE for the first time
     */
    function initializeTimelockAdmin(address timelockAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (timelockAdmin == address(0)) revert ZeroAddressException();
        if (_timelockAdminInitialized) revert TimelockAdminAlreadyInitialized();

        _timelockAdminInitialized = true;
        _grantRole(TIMELOCK_ADMIN_ROLE, timelockAdmin);
        emit TimelockAdminUpdated(address(0), timelockAdmin);
    }

    /**
     * @notice Set a new timelock admin - must be called via timelock
     * @param newTimelockAdmin New timelock admin address
     * @dev This is the ONLY way to change TIMELOCK_ADMIN_ROLE after initialization
     */
    function setTimelockAdmin(address newTimelockAdmin) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        if (newTimelockAdmin == address(0)) revert ZeroAddressException();

        // Find current timelock admin (there should be exactly one)
        address currentAdmin = msg.sender;

        _revokeRole(TIMELOCK_ADMIN_ROLE, currentAdmin);
        _grantRole(TIMELOCK_ADMIN_ROLE, newTimelockAdmin);

        emit TimelockAdminUpdated(currentAdmin, newTimelockAdmin);
    }

    /**
     * @dev Override grantRole to block direct TIMELOCK_ADMIN_ROLE grants
     */
    function grantRole(bytes32 role, address account) public virtual override {
        if (role == TIMELOCK_ADMIN_ROLE) revert UseSetTimelockAdmin();
        super.grantRole(role, account);
    }

    /**
     * @dev Override revokeRole to block direct TIMELOCK_ADMIN_ROLE revocations
     */
    function revokeRole(bytes32 role, address account) public virtual override {
        if (role == TIMELOCK_ADMIN_ROLE) revert UseSetTimelockAdmin();
        super.revokeRole(role, account);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(TIMELOCK_ADMIN_ROLE) { }

    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
