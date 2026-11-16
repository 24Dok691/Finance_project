// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title EsepInvoiceEscrow
 * @notice Educational prototype for SME invoice financing (factoring) on a permissioned EVM network.
 * @dev Prevents double-pledging via unique invoiceHash registry and enforces CEI + ReentrancyGuard.
 */
contract EsepInvoiceEscrow is AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant SME_ROLE = keccak256("SME_ROLE");
    bytes32 public constant BUYER_ROLE = keccak256("BUYER_ROLE");
    bytes32 public constant INVESTOR_ROLE = keccak256("INVESTOR_ROLE");

    uint256 public constant PLATFORM_FEE_BPS = 150; // 1.50% origination fee (150 basis points)
    uint256 public constant BPS_DENOMINATOR = 10000;

    address public treasury;

    enum InvoiceStatus {
        Registered,
        Verified,
        Funded,
        Settled
    }

    struct Invoice {
        bytes32 invoiceHash;
        address sme;
        address buyer;
        address investor;
        uint256 faceValue;
        uint256 fundedAmount;
        uint256 dueDate;
        InvoiceStatus status;
    }

    mapping(bytes32 => Invoice) public invoices;
    mapping(bytes32 => bool) public registeredHashes;

    event InvoiceRegistered(bytes32 indexed invoiceHash, address indexed sme, address indexed buyer, uint256 faceValue, uint256 dueDate);
    event InvoiceVerified(bytes32 indexed invoiceHash, address indexed buyer);
    event InvoiceFunded(bytes32 indexed invoiceHash, address indexed investor, uint256 netToSme, uint256 platformFee);
    event InvoiceSettled(bytes32 indexed invoiceHash, address indexed buyer, address indexed investor, uint256 faceValue);

    constructor(address _treasury) {
        require(_treasury != address(0), "Invalid treasury address");
        treasury = _treasury;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Step 1: SME registers a unique invoice hash to prevent double-pledging.
     */
    function registerInvoice(
        bytes32 _invoiceHash,
        address _buyer,
        uint256 _faceValue,
        uint256 _dueDate
    ) external onlyRole(SME_ROLE) whenNotPaused {
        require(_invoiceHash != bytes32(0), "Empty invoice hash");
        require(!registeredHashes[_invoiceHash], "Duplicate invoice: already registered");
        require(hasRole(BUYER_ROLE, _buyer), "Recipient is not an onboarded buyer");
        require(_faceValue > 0, "Face value must be positive");
        require(_dueDate > block.timestamp, "Due date must be in the future");

        registeredHashes[_invoiceHash] = true;

        invoices[_invoiceHash] = Invoice({
            invoiceHash: _invoiceHash,
            sme: msg.sender,
            buyer: _buyer,
            investor: address(0),
            faceValue: _faceValue,
            fundedAmount: 0,
            dueDate: _dueDate,
            status: InvoiceStatus.Registered
        });

        emit InvoiceRegistered(_invoiceHash, msg.sender, _buyer, _faceValue, _dueDate);
    }

    /**
     * @notice Step 2: Corporate buyer confirms the invoice obligation is valid.
     */
    function verifyInvoice(bytes32 _invoiceHash) external onlyRole(BUYER_ROLE) whenNotPaused {
        Invoice storage inv = invoices[_invoiceHash];
        require(registeredHashes[_invoiceHash], "Invoice does not exist");
        require(inv.buyer == msg.sender, "Only designated buyer can verify");
        require(inv.status == InvoiceStatus.Registered, "Invalid invoice status");

        inv.status = InvoiceStatus.Verified;
        emit InvoiceVerified(_invoiceHash, msg.sender);
    }

    /**
     * @notice Step 3: Investor purchases the verified invoice at a discount; SME receives immediate liquidity.
     */
    function fundInvoice(bytes32 _invoiceHash) external payable onlyRole(INVESTOR_ROLE) nonReentrant whenNotPaused {
        Invoice storage inv = invoices[_invoiceHash];
        require(inv.status == InvoiceStatus.Verified, "Invoice must be verified first");
        require(msg.value > 0 && msg.value < inv.faceValue, "Discounted price must be < face value");

        uint256 platformFee = (inv.faceValue * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        require(msg.value > platformFee, "Funded amount must exceed platform fee");
        uint256 netToSme = msg.value - platformFee;

        // Effects before Interactions (CEI pattern)
        inv.investor = msg.sender;
        inv.fundedAmount = msg.value;
        inv.status = InvoiceStatus.Funded;

        // Interactions
        (bool feeSent, ) = payable(treasury).call{value: platformFee}("");
        require(feeSent, "Treasury fee transfer failed");

        (bool smeSent, ) = payable(inv.sme).call{value: netToSme}("");
        require(smeSent, "SME payout transfer failed");

        emit InvoiceFunded(_invoiceHash, msg.sender, netToSme, platformFee);
    }

    /**
     * @notice Step 4: Buyer settles full face value at maturity; funds route directly to the investor.
     */
    function settleInvoice(bytes32 _invoiceHash) external payable onlyRole(BUYER_ROLE) nonReentrant whenNotPaused {
        Invoice storage inv = invoices[_invoiceHash];
        require(inv.buyer == msg.sender, "Only designated buyer can settle");
        require(inv.status == InvoiceStatus.Funded, "Invoice is not funded");
        require(msg.value == inv.faceValue, "Must pay exact face value");

        // Effects
        inv.status = InvoiceStatus.Settled;

        // Interactions
        (bool investorSent, ) = payable(inv.investor).call{value: msg.value}("");
        require(investorSent, "Investor settlement transfer failed");

        emit InvoiceSettled(_invoiceHash, msg.sender, inv.investor, msg.value);
    }
}