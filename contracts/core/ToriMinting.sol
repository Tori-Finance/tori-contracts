// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";

interface ITrUSD {
    function mint(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
}

/**
 * @title ToriMinting
 * @notice Signature-based minting and redemption contract for TrUSD
 */
contract ToriMinting is AccessControlDefaultAdminRules, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /* ========== CONSTANTS ========== */

    bytes32 private constant EIP712_DOMAIN =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant ORDER_TYPE = keccak256(
        "Order(uint8 order_type,address sender,address recipient,address collateral_asset,uint128 collateral_amount,uint128 trusd_amount,uint128 expiry,uint256 nonce,string order_id)"
    );

    bytes32 private constant EIP_712_NAME = keccak256("ToriMinting");
    bytes32 private constant EIP712_REVISION = keccak256("1");
    uint128 private constant STABLES_RATIO_MULTIPLIER = 10_000;

    /* ========== ROLES ========== */

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
    bytes32 public constant GATEKEEPER_ROLE = keccak256("GATEKEEPER_ROLE");
    bytes32 public constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");
    bytes32 public constant WHITELISTER_ROLE = keccak256("WHITELISTER_ROLE");
    /// @notice Role for timelock-protected operations (addAllowedToken)
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    /* ========== ENUMS ========== */

    enum OrderType {
        MINT,
        REDEEM
    }

    enum SignatureType {
        EIP712,
        EIP1271
    }

    enum TokenType {
        STABLE
    }

    /* ========== STRUCTS ========== */

    struct Order {
        OrderType order_type;
        address sender;
        address recipient;
        address collateral_asset;
        uint128 collateral_amount;
        uint128 trusd_amount;
        uint128 expiry;
        uint256 nonce;
        string order_id;
    }

    struct Signature {
        SignatureType signature_type;
        bytes signature_bytes;
    }

    struct TokenConfig {
        TokenType tokenType;
        bool isActive;
        uint128 maxMintPerBlock;
        uint128 maxRedeemPerBlock;
    }

    struct BlockTotals {
        uint128 mintedPerBlock;
        uint128 redeemedPerBlock;
    }

    struct Route {
        address[] addresses;
        uint128[] ratios;
    }

    /* ========== STATE VARIABLES ========== */

    address public immutable TRUSD_ADDRESS;

    mapping(address => bool) public whitelisted;
    mapping(address => EnumerableSet.AddressSet) private _approvedRecipientsPerSender;
    mapping(address => TokenConfig) public tokenConfig;

    uint128 public globalMaxMintPerBlock;
    uint128 public globalMaxRedeemPerBlock;

    mapping(uint256 => BlockTotals) public totalPerBlock;
    mapping(uint256 => mapping(address => BlockTotals)) public totalPerBlockPerAsset;
    mapping(address => mapping(uint256 => uint256)) private _orderBitmaps;

    uint256 private immutable CHAIN_ID;
    bytes32 private immutable DOMAIN_SEPARATOR;
    uint128 public stablesDeltaLimit;

    EnumerableSet.AddressSet private _custodianAddresses;
    bool private _timelockAdminInitialized;

    /* ========== EVENTS ========== */

    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event MaxMintPerBlockChanged(uint128 oldMaxMintPerBlock, uint128 newMaxMintPerBlock, address indexed asset);
    event MaxRedeemPerBlockChanged(uint128 oldMaxRedeemPerBlock, uint128 newMaxRedeemPerBlock, address indexed asset);
    event GlobalLimitsUpdated(uint128 globalMaxMintPerBlock, uint128 globalMaxRedeemPerBlock);
    event UserWhitelisted(address indexed user);
    event UserRemovedFromWhitelist(address indexed user);
    event Minted(
        address indexed sender,
        address indexed recipient,
        address indexed collateral_asset,
        uint128 collateral_amount,
        uint128 trusd_amount,
        string order_id
    );
    event Redeemed(
        address indexed sender,
        address indexed recipient,
        address indexed collateral_asset,
        uint128 trusd_amount,
        uint128 collateral_amount,
        string order_id
    );
    event CustodianAddressAdded(address indexed custodian);
    event CustodianAddressRemoved(address indexed custodian);
    event RecipientAdded(address indexed sender, address indexed recipient);
    event RecipientRemoved(address indexed sender, address indexed recipient);
    event TimelockAdminUpdated(address indexed oldTimelockAdmin, address indexed newTimelockAdmin);

    /* ========== ERRORS ========== */

    error ZeroAddress();
    error UseSetTimelockAdmin();
    error TimelockAdminAlreadyInitialized();
    error NotWhitelisted(address user);
    error TokenNotAllowed(address token);
    error InvalidAmount();
    error InvalidTokenAddress();
    error UnsupportedAsset();
    error MaxMintPerBlockExceeded();
    error MaxRedeemPerBlockExceeded();
    error GlobalMaxMintPerBlockExceeded();
    error GlobalMaxRedeemPerBlockExceeded();
    error InvalidOrder();
    error InvalidNonce();
    error InvalidEIP712Signature();
    error InvalidEIP1271Signature();
    error UnknownSignatureType();
    error SignatureExpired();
    error InvalidStablePrice();
    error InvalidAddress();
    error InvalidCustodianAddress();
    error InvalidRoute();
    error RecipientNotApproved();

    /* ========== MODIFIERS ========== */

    modifier belowMaxMintPerBlock(uint128 mintAmount, address asset) {
        TokenConfig memory config = tokenConfig[asset];
        if (!config.isActive) revert UnsupportedAsset();
        if (totalPerBlockPerAsset[block.number][asset].mintedPerBlock + mintAmount > config.maxMintPerBlock) {
            revert MaxMintPerBlockExceeded();
        }
        _;
    }

    modifier belowMaxRedeemPerBlock(uint128 redeemAmount, address asset) {
        TokenConfig memory config = tokenConfig[asset];
        if (!config.isActive) revert UnsupportedAsset();
        if (totalPerBlockPerAsset[block.number][asset].redeemedPerBlock + redeemAmount > config.maxRedeemPerBlock) {
            revert MaxRedeemPerBlockExceeded();
        }
        _;
    }

    modifier belowGlobalMaxMintPerBlock(uint128 mintAmount) {
        if (totalPerBlock[block.number].mintedPerBlock + mintAmount > globalMaxMintPerBlock) {
            revert GlobalMaxMintPerBlockExceeded();
        }
        _;
    }

    modifier belowGlobalMaxRedeemPerBlock(uint128 redeemAmount) {
        if (totalPerBlock[block.number].redeemedPerBlock + redeemAmount > globalMaxRedeemPerBlock) {
            revert GlobalMaxRedeemPerBlockExceeded();
        }
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _trUSDAddress,
        address[] memory _allowedTokens,
        TokenConfig[] memory _tokenConfigs,
        uint128 _globalMaxMintPerBlock,
        uint128 _globalMaxRedeemPerBlock,
        address _admin
    )
        AccessControlDefaultAdminRules(1 days, _admin)
    {
        if (_admin == address(0)) revert ZeroAddress();
        if (_trUSDAddress == address(0)) revert ZeroAddress();
        if (_allowedTokens.length != _tokenConfigs.length) revert InvalidAmount();
        if (_allowedTokens.length == 0) revert InvalidAmount();

        TRUSD_ADDRESS = _trUSDAddress;
        globalMaxMintPerBlock = _globalMaxMintPerBlock;
        globalMaxRedeemPerBlock = _globalMaxRedeemPerBlock;

        for (uint256 i = 0; i < _allowedTokens.length; i++) {
            address token = _allowedTokens[i];
            TokenConfig memory config = _tokenConfigs[i];

            if (token == address(0) || token == _trUSDAddress || token.code.length == 0) {
                revert InvalidTokenAddress();
            }
            if (config.maxMintPerBlock == 0 || config.maxRedeemPerBlock == 0) revert InvalidAmount();

            tokenConfig[token] = TokenConfig({
                tokenType: config.tokenType,
                isActive: true,
                maxMintPerBlock: config.maxMintPerBlock,
                maxRedeemPerBlock: config.maxRedeemPerBlock
            });
            emit TokenAdded(token);
        }

        CHAIN_ID = block.chainid;
        DOMAIN_SEPARATOR = _computeDomainSeparator();
    }

    /* ========== USER FUNCTIONS ========== */

    /**
     * @notice Mint TrUSD with user-signed order
     * @param order Order details
     * @param signature User's EIP-712 / EIP-1271 signature
     * @param route Custody routing for collateral
     */
    function mint(
        Order calldata order,
        Signature calldata signature,
        Route calldata route
    )
        external
        nonReentrant
        whenNotPaused
        onlyRole(MINTER_ROLE)
        belowMaxMintPerBlock(order.trusd_amount, order.collateral_asset)
        belowGlobalMaxMintPerBlock(order.trusd_amount)
    {
        if (order.order_type != OrderType.MINT) revert InvalidOrder();
        if (!whitelisted[order.sender]) revert NotWhitelisted(order.sender);

        verifyOrder(order, signature);
        if (!verifyRoute(route)) revert InvalidRoute();
        _deduplicateOrder(order.sender, order.nonce);

        totalPerBlockPerAsset[block.number][order.collateral_asset].mintedPerBlock += order.trusd_amount;
        totalPerBlock[block.number].mintedPerBlock += order.trusd_amount;

        _transferCollateral(
            order.collateral_amount, order.collateral_asset, order.sender, route.addresses, route.ratios
        );
        ITrUSD(TRUSD_ADDRESS).mint(order.recipient, order.trusd_amount);

        emit Minted(
            order.sender,
            order.recipient,
            order.collateral_asset,
            order.collateral_amount,
            order.trusd_amount,
            order.order_id
        );
    }

    /**
     * @notice Redeem TrUSD for collateral
     * @param order Order details
     * @param signature User's EIP-712 signature
     */
    function redeem(
        Order calldata order,
        Signature calldata signature
    )
        external
        nonReentrant
        whenNotPaused
        onlyRole(REDEEMER_ROLE)
        belowMaxRedeemPerBlock(order.trusd_amount, order.collateral_asset)
        belowGlobalMaxRedeemPerBlock(order.trusd_amount)
    {
        if (order.order_type != OrderType.REDEEM) revert InvalidOrder();
        if (!whitelisted[order.sender]) revert NotWhitelisted(order.sender);

        verifyOrder(order, signature);
        _deduplicateOrder(order.sender, order.nonce);

        totalPerBlockPerAsset[block.number][order.collateral_asset].redeemedPerBlock += order.trusd_amount;
        totalPerBlock[block.number].redeemedPerBlock += order.trusd_amount;

        ITrUSD(TRUSD_ADDRESS).burnFrom(order.sender, order.trusd_amount);
        IERC20(order.collateral_asset).safeTransfer(order.recipient, order.collateral_amount);

        emit Redeemed(
            order.sender,
            order.recipient,
            order.collateral_asset,
            order.trusd_amount,
            order.collateral_amount,
            order.order_id
        );
    }

    /* ========== ADMIN FUNCTIONS ========== */

    function addAllowedToken(address _token, TokenConfig memory _config) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        if (_token == address(0) || _token == TRUSD_ADDRESS || _token.code.length == 0) {
            revert InvalidTokenAddress();
        }
        if (_config.maxMintPerBlock == 0 || _config.maxRedeemPerBlock == 0) revert InvalidAmount();

        tokenConfig[_token] = TokenConfig({
            isActive: true,
            tokenType: _config.tokenType,
            maxMintPerBlock: _config.maxMintPerBlock,
            maxRedeemPerBlock: _config.maxRedeemPerBlock
        });
        emit TokenAdded(_token);
    }

    function removeAllowedToken(address _token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_token == address(0)) revert ZeroAddress();
        if (tokenConfig[_token].maxMintPerBlock == 0 && tokenConfig[_token].maxRedeemPerBlock == 0) {
            revert TokenNotAllowed(_token);
        }
        delete tokenConfig[_token];
        emit TokenRemoved(_token);
    }

    function enableAllowedToken(address _token) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        if (_token == address(0)) revert ZeroAddress();
        if (tokenConfig[_token].maxMintPerBlock == 0) revert TokenNotAllowed(_token);
        tokenConfig[_token].isActive = true;
    }

    function disableAllowedToken(address _token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_token == address(0)) revert ZeroAddress();
        if (!tokenConfig[_token].isActive) revert TokenNotAllowed(_token);
        tokenConfig[_token].isActive = false;
    }

    function setStablesDeltaLimit(uint128 _stablesDeltaLimit) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        stablesDeltaLimit = _stablesDeltaLimit;
    }

    function setGlobalLimits(
        uint128 _globalMaxMintPerBlock,
        uint128 _globalMaxRedeemPerBlock
    )
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        globalMaxMintPerBlock = _globalMaxMintPerBlock;
        globalMaxRedeemPerBlock = _globalMaxRedeemPerBlock;
        emit GlobalLimitsUpdated(_globalMaxMintPerBlock, _globalMaxRedeemPerBlock);
    }

    function setMaxMintPerBlock(uint128 _maxMintPerBlock, address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!tokenConfig[asset].isActive) revert TokenNotAllowed(asset);
        uint128 oldMaxMintPerBlock = tokenConfig[asset].maxMintPerBlock;
        tokenConfig[asset].maxMintPerBlock = _maxMintPerBlock;
        emit MaxMintPerBlockChanged(oldMaxMintPerBlock, _maxMintPerBlock, asset);
    }

    function setMaxRedeemPerBlock(uint128 _maxRedeemPerBlock, address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!tokenConfig[asset].isActive) revert TokenNotAllowed(asset);
        uint128 oldMaxRedeemPerBlock = tokenConfig[asset].maxRedeemPerBlock;
        tokenConfig[asset].maxRedeemPerBlock = _maxRedeemPerBlock;
        emit MaxRedeemPerBlockChanged(oldMaxRedeemPerBlock, _maxRedeemPerBlock, asset);
    }

    function addToWhitelist(address _user) external onlyRole(WHITELISTER_ROLE) {
        if (_user == address(0)) revert ZeroAddress();
        whitelisted[_user] = true;
        emit UserWhitelisted(_user);
    }

    function addToWhitelistBatch(address[] calldata _users) external onlyRole(WHITELISTER_ROLE) {
        for (uint256 i = 0; i < _users.length; i++) {
            if (_users[i] != address(0)) {
                whitelisted[_users[i]] = true;
                emit UserWhitelisted(_users[i]);
            }
        }
    }

    function removeFromWhitelist(address _user) external onlyRole(WHITELISTER_ROLE) {
        whitelisted[_user] = false;
        emit UserRemovedFromWhitelist(_user);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function disableMintRedeem() external onlyRole(GATEKEEPER_ROLE) {
        globalMaxMintPerBlock = 0;
        globalMaxRedeemPerBlock = 0;
    }

    /// @notice Removes the minter role from an account, this can ONLY be executed by the gatekeeper role
    /// @param minter The address to remove the minter role from
    function removeMinterRole(address minter) external onlyRole(GATEKEEPER_ROLE) {
        _revokeRole(MINTER_ROLE, minter);
    }

    /// @notice Removes the redeemer role from an account, this can ONLY be executed by the gatekeeper role
    /// @param redeemer The address to remove the redeemer role from
    function removeRedeemerRole(address redeemer) external onlyRole(GATEKEEPER_ROLE) {
        _revokeRole(REDEEMER_ROLE, redeemer);
    }

    /// @notice Removes the collateral manager role from an account, this can ONLY be executed by the gatekeeper role
    /// @param collateralManager The address to remove the collateral manager role from
    function removeCollateralManagerRole(address collateralManager) external onlyRole(GATEKEEPER_ROLE) {
        _revokeRole(COLLATERAL_MANAGER_ROLE, collateralManager);
    }

    /**
     * @notice Initialize the timelock admin - can only be called once by DEFAULT_ADMIN
     * @param timelockAdmin Address of the timelock contract
     * @dev This bootstraps the TIMELOCK_ADMIN_ROLE for the first time
     */
    function initializeTimelockAdmin(address timelockAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (timelockAdmin == address(0)) revert ZeroAddress();
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
        if (newTimelockAdmin == address(0)) revert ZeroAddress();

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

    /* ========== RECIPIENT MANAGEMENT ========== */

    function setApprovedRecipient(address recipient, bool status) public {
        if (recipient == address(0)) revert InvalidAddress();

        if (status) {
            if (!_approvedRecipientsPerSender[msg.sender].add(recipient)) {
                revert InvalidAddress();
            }
            emit RecipientAdded(msg.sender, recipient);
        } else {
            if (!_approvedRecipientsPerSender[msg.sender].remove(recipient)) {
                revert InvalidAddress();
            }
            emit RecipientRemoved(msg.sender, recipient);
        }
    }

    function isApprovedRecipient(address sender, address recipient) public view returns (bool) {
        return _approvedRecipientsPerSender[sender].contains(recipient);
    }

    /* ========== CUSTODIAN MANAGEMENT ========== */

    function addCustodianAddress(address custodian) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        if (custodian == address(0) || custodian == address(this)) revert InvalidAddress();
        if (_custodianAddresses.contains(custodian)) revert InvalidCustodianAddress();

        _custodianAddresses.add(custodian);
        emit CustodianAddressAdded(custodian);
    }

    function removeCustodianAddress(address custodian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_custodianAddresses.contains(custodian)) revert InvalidCustodianAddress();

        _custodianAddresses.remove(custodian);
        emit CustodianAddressRemoved(custodian);
    }

    function transferToCustody(
        address asset,
        uint256 amount,
        Route calldata route
    )
        external
        nonReentrant
        onlyRole(COLLATERAL_MANAGER_ROLE)
    {
        uint256 totalRatio;
        uint256 amountToTransfer;
        uint256 totalTransferred;

        if (route.addresses.length != route.ratios.length || route.addresses.length == 0) {
            revert InvalidRoute();
        }

        for (uint256 i = 0; i < route.addresses.length;) {
            if (!_custodianAddresses.contains(route.addresses[i])) {
                revert InvalidCustodianAddress();
            }
            totalRatio += route.ratios[i];
            unchecked {
                ++i;
            }
        }

        if (totalRatio != 10_000) revert InvalidRoute();

        for (uint256 i = 0; i < route.addresses.length;) {
            amountToTransfer = (amount * route.ratios[i]) / 10_000;
            if (amountToTransfer > 0) {
                IERC20(asset).safeTransfer(route.addresses[i], amountToTransfer);
                totalTransferred += amountToTransfer;
            }
            unchecked {
                ++i;
            }
        }

        // Handle rounding remainder - send to last custodian
        uint256 remainder = amount - totalTransferred;
        if (remainder > 0) {
            IERC20(asset).safeTransfer(route.addresses[route.addresses.length - 1], remainder);
        }
    }

    function getCustodianAddresses() external view returns (address[] memory) {
        return _custodianAddresses.values();
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getDomainSeparator() public view returns (bytes32) {
        if (block.chainid == CHAIN_ID) {
            return DOMAIN_SEPARATOR;
        }
        return _computeDomainSeparator();
    }

    function hashOrder(Order calldata order) public view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(getDomainSeparator(), keccak256(encodeOrder(order)));
    }

    function encodeOrder(Order calldata order) public pure returns (bytes memory) {
        return abi.encode(
            ORDER_TYPE,
            order.order_type,
            order.sender,
            order.recipient,
            order.collateral_asset,
            order.collateral_amount,
            order.trusd_amount,
            order.expiry,
            order.nonce,
            keccak256(bytes(order.order_id))
        );
    }

    function verifyOrder(Order calldata order, Signature calldata signature) public view returns (bytes32) {
        bytes32 orderHash = hashOrder(order);

        if (signature.signature_type == SignatureType.EIP712) {
            // EOA signature verification
            address signer = ECDSA.recover(orderHash, signature.signature_bytes);
            if (signer != order.sender) revert InvalidEIP712Signature();
        } else if (signature.signature_type == SignatureType.EIP1271) {
            // Smart contract wallet signature verification (Gnosis Safe, Argent, etc.)
            if (
                IERC1271(order.sender).isValidSignature(orderHash, signature.signature_bytes)
                    != IERC1271.isValidSignature.selector
            ) {
                revert InvalidEIP1271Signature();
            }
        } else {
            revert UnknownSignatureType();
        }

        if (order.sender != order.recipient) {
            if (!_approvedRecipientsPerSender[order.sender].contains(order.recipient)) {
                revert RecipientNotApproved();
            }
        }

        if (order.recipient == address(0)) revert InvalidAddress();
        if (!tokenConfig[order.collateral_asset].isActive) revert TokenNotAllowed(order.collateral_asset);

        if (order.collateral_amount == 0 || order.trusd_amount == 0) revert InvalidAmount();

        if (tokenConfig[order.collateral_asset].tokenType != TokenType.STABLE) {
            revert UnsupportedAsset();
        }
        if (!verifyStablesLimit(order.collateral_amount, order.trusd_amount, order.collateral_asset, order.order_type))
        {
            revert InvalidStablePrice();
        }
        if (block.timestamp > order.expiry) revert SignatureExpired();

        return orderHash;
    }

    function verifyNonce(address sender, uint256 nonce) public view returns (uint256, uint256, uint256) {
        if (nonce == 0) revert InvalidNonce();
        uint256 invalidatorSlot = uint128(nonce) >> 8;
        uint256 invalidatorBit = 1 << uint8(nonce);
        uint256 invalidator = _orderBitmaps[sender][invalidatorSlot];
        if (invalidator & invalidatorBit != 0) revert InvalidNonce();

        return (invalidatorSlot, invalidator, invalidatorBit);
    }

    function verifyRoute(Route calldata route) public view returns (bool) {
        uint128 totalRatio = 0;

        // Route must have matching lengths
        if (route.addresses.length != route.ratios.length) {
            return false;
        }

        // Route cannot be empty
        if (route.addresses.length == 0) {
            return false;
        }

        // Validate each address is approved custodian and sum ratios
        for (uint128 i = 0; i < route.addresses.length;) {
            if (
                !_custodianAddresses.contains(route.addresses[i]) || route.addresses[i] == address(0)
                    || route.ratios[i] == 0
            ) {
                return false;
            }
            totalRatio += route.ratios[i];
            unchecked {
                ++i;
            }
        }

        // Total ratio must equal 10000 (100%)
        return (totalRatio == 10_000);
    }

    function isSupportedAsset(address asset) external view returns (bool) {
        return tokenConfig[asset].isActive;
    }

    function verifyStablesLimit(
        uint128 collateralAmount,
        uint128 trusdAmount,
        address collateralAsset,
        OrderType orderType
    )
        public
        view
        returns (bool)
    {
        uint128 trusdDecimals = _getDecimals(TRUSD_ADDRESS);
        uint128 collateralDecimals = _getDecimals(collateralAsset);

        uint128 normalizedCollateralAmount;
        uint128 scale = uint128(
            trusdDecimals > collateralDecimals
                ? 10 ** (trusdDecimals - collateralDecimals)
                : 10 ** (collateralDecimals - trusdDecimals)
        );

        normalizedCollateralAmount =
            trusdDecimals > collateralDecimals ? collateralAmount * scale : collateralAmount / scale;

        uint128 difference = normalizedCollateralAmount > trusdAmount
            ? normalizedCollateralAmount - trusdAmount
            : trusdAmount - normalizedCollateralAmount;

        uint128 differenceInBps = (difference * STABLES_RATIO_MULTIPLIER) / trusdAmount;

        if (orderType == OrderType.MINT) {
            return trusdAmount > normalizedCollateralAmount ? differenceInBps <= stablesDeltaLimit : true;
        } else {
            return normalizedCollateralAmount > trusdAmount ? differenceInBps <= stablesDeltaLimit : true;
        }
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _deduplicateOrder(address sender, uint256 nonce) internal {
        (uint256 invalidatorSlot, uint256 invalidator, uint256 invalidatorBit) = verifyNonce(sender, nonce);
        _orderBitmaps[sender][invalidatorSlot] = invalidator | invalidatorBit;
    }

    function _transferCollateral(
        uint128 amount,
        address asset,
        address from,
        address[] calldata addresses,
        uint128[] calldata ratios
    )
        internal
    {
        if (!tokenConfig[asset].isActive) revert UnsupportedAsset();

        IERC20 token = IERC20(asset);
        uint128 totalTransferred = 0;

        for (uint128 i = 0; i < addresses.length;) {
            uint128 amountToTransfer = (amount * ratios[i]) / 10_000;
            token.safeTransferFrom(from, addresses[i], amountToTransfer);
            totalTransferred += amountToTransfer;
            unchecked {
                ++i;
            }
        }

        uint128 remainingBalance = amount - totalTransferred;
        if (remainingBalance > 0) {
            token.safeTransferFrom(from, addresses[addresses.length - 1], remainingBalance);
        }
    }

    function _computeDomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN, EIP_712_NAME, EIP712_REVISION, block.chainid, address(this)));
    }

    function _getDecimals(address token) internal view returns (uint128) {
        uint8 decimals = IERC20Metadata(token).decimals();
        return uint128(decimals);
    }
}
