// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MultiSigERC20EscrowEIP712 is EIP712 {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    enum Action {
        DONE,   // 正常完了（Payeeへの全額送金）
        REFUND, // 割合指定キャンセル（PayerとPayeeで分割）
        CANCEL  // 完全キャンセル（Payerへの全額返金）
    }

    struct Allocation {
        address recipient;
        uint256 amount;
    }

    struct Escrow {
        address payer;
        address payee;
        address relayer;
        address token;       // ERC-20トークンのコントラクトアドレス
        uint256 totalAmount; // ロックするトークン数量
        uint256 deadline;    // エスクローの有効期限
        bool isFunded;
        bool isExecuted;
    }

    struct Proposal {
        uint8 approvalCount;
        mapping(address => bool) hasApproved;
    }

    bytes32 private constant ALLOCATION_TYPEHASH = 
        keccak256("Allocation(address recipient,uint256 amount)");

    bytes32 private constant EXECUTE_TYPEHASH = 
        keccak256(
            "Execute(bytes32 escrowId,uint8 action,Allocation[] allocations)Allocation(address recipient,uint256 amount)"
        );

    mapping(bytes32 => Escrow) public escrows;
    
    // escrowId => (proposalHash => Proposal)
    mapping(bytes32 => mapping(bytes32 => Proposal)) private proposals;

    event EscrowCreated(
        bytes32 indexed escrowId, 
        address indexed payer, 
        address indexed token, 
        uint256 amount,
        uint256 deadline
    );
    event Approved(bytes32 indexed escrowId, bytes32 indexed proposalHash, address indexed signer, uint8 approvalCount);
    event Executed(bytes32 indexed escrowId, Action indexed action, address indexed caller);
    event ClaimedAfterDeadline(bytes32 indexed escrowId, address indexed payee, uint256 amount);

    constructor() EIP712("ERC20EscrowSystem", "1") {}

    /**
     * @notice エスクローの作成とデポジット（Deadlineを設定）
     */
    function createEscrow(
        bytes32 escrowId,
        address payee,
        address relayer,
        address token,
        uint256 amount,
        uint256 deadline
    ) external {
        require(escrows[escrowId].payer == address(0), "Escrow exists");
        require(payee != address(0) && relayer != address(0), "Invalid address");
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Zero amount");
        require(deadline > block.timestamp, "Deadline must be in future");

        escrows[escrowId] = Escrow({
            payer: msg.sender,
            payee: payee,
            relayer: relayer,
            token: token,
            totalAmount: amount,
            deadline: deadline,
            isFunded: true,
            isExecuted: false
        });

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit EscrowCreated(escrowId, msg.sender, token, amount, deadline);
    }

    /**
     * @notice 直接トランザクションを発行して分配案に署名（承認）する
     */
    function signExecute(
        bytes32 escrowId,
        Action action,
        Allocation[] calldata allocations
    ) external {
        _approveAndExecute(escrowId, action, allocations, msg.sender);
    }

    /**
     * @notice EIP-712 署名（オフチェーン署名データ）を提出して代理実行・承認する
     */
    function signExecuteBySig(
        bytes32 escrowId,
        Action action,
        Allocation[] calldata allocations,
        bytes calldata signature
    ) external {
        bytes32 structHash = _getStructHash(escrowId, action, allocations);
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(signature);

        _approveAndExecute(escrowId, action, allocations, signer);
    }

    /**
     * @notice Deadlineを過ぎた場合に自動でpayeeへ全額送金する（誰でも呼び出し可能）
     */
    function claimAfterDeadline(bytes32 escrowId) external {
        Escrow storage escrow = escrows[escrowId];
        require(escrow.isFunded, "Not funded");
        require(!escrow.isExecuted, "Already executed");
        require(block.timestamp > escrow.deadline, "Deadline not reached");

        escrow.isExecuted = true;

        IERC20(escrow.token).safeTransfer(escrow.payee, escrow.totalAmount);

        emit ClaimedAfterDeadline(escrowId, escrow.payee, escrow.totalAmount);
    }

    /**
     * @notice 【Etherscan用】現在の提案に対する承認数および各メンバーの承認状態を確認するヘルパー関数
     */
    function getProposalStatus(
        bytes32 escrowId,
        Action action,
        Allocation[] calldata allocations
    ) external view returns (
        uint8 approvalCount,
        bool approvedByPayer,
        bool approvedByPayee,
        bool approvedByRelayer
    ) {
        Escrow storage escrow = escrows[escrowId];
        bytes32 proposalHash = _getStructHash(escrowId, action, allocations);
        Proposal storage proposal = proposals[escrowId][proposalHash];

        return (
            proposal.approvalCount,
            proposal.hasApproved[escrow.payer],
            proposal.hasApproved[escrow.payee],
            proposal.hasApproved[escrow.relayer]
        );
    }

    /**
     * @dev 承認記録および2つ以上の承認が集まった場合の自動実行ロジック
     */
    function _approveAndExecute(
        bytes32 escrowId,
        Action action,
        Allocation[] calldata allocations,
        address signer
    ) internal {
        Escrow storage escrow = escrows[escrowId];
        require(escrow.isFunded, "Not funded");
        require(!escrow.isExecuted, "Already executed");
        require(block.timestamp <= escrow.deadline, "Escrow expired");

        require(
            signer == escrow.payer || signer == escrow.payee || signer == escrow.relayer,
            "Unauthorized signer"
        );

        _validateAllocations(escrow, action, allocations);

        bytes32 proposalHash = _getStructHash(escrowId, action, allocations);
        Proposal storage proposal = proposals[escrowId][proposalHash];

        require(!proposal.hasApproved[signer], "Already approved");

        proposal.hasApproved[signer] = true;
        proposal.approvalCount++;

        emit Approved(escrowId, proposalHash, signer, proposal.approvalCount);

        if (proposal.approvalCount >= 2) {
            escrow.isExecuted = true;

            IERC20 token = IERC20(escrow.token);
            for (uint256 i = 0; i < allocations.length; i++) {
                if (allocations[i].amount > 0) {
                    token.safeTransfer(allocations[i].recipient, allocations[i].amount);
                }
            }

            emit Executed(escrowId, action, msg.sender);
        }
    }

    function _validateAllocations(
        Escrow storage escrow,
        Action action,
        Allocation[] calldata allocations
    ) internal view {
        uint256 totalAllocated = 0;
        for (uint256 i = 0; i < allocations.length; i++) {
            totalAllocated += allocations[i].amount;
        }
        require(totalAllocated == escrow.totalAmount, "Total amount mismatch");

        if (action == Action.DONE) {
            require(allocations.length == 1, "Requires 1 allocation");
            require(allocations[0].recipient == escrow.payee, "Recipient must be payee");
        } 
        else if (action == Action.CANCEL) {
            require(allocations.length == 1, "CANCEL requires 1 allocation");
            require(allocations[0].recipient == escrow.payer, "Recipient must be payer");
        } 
        else if (action == Action.REFUND) {
            for (uint256 i = 0; i < allocations.length; i++) {
                address r = allocations[i].recipient;
                require(r == escrow.payer || r == escrow.payee, "Invalid REFUND recipient");
            }
        }
    }

    function _getStructHash(
        bytes32 escrowId,
        Action action,
        Allocation[] calldata allocations
    ) internal pure returns (bytes32) {
        bytes32[] memory allocHashes = new bytes32[](allocations.length);
        for (uint256 i = 0; i < allocations.length; i++) {
            allocHashes[i] = keccak256(
                abi.encode(ALLOCATION_TYPEHASH, allocations[i].recipient, allocations[i].amount)
            );
        }

        return keccak256(
            abi.encode(
                EXECUTE_TYPEHASH,
                escrowId,
                action,
                keccak256(abi.encodePacked(allocHashes))
            )
        );
    }
}