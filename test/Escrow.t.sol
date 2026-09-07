// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../src/MultiSigEscrow.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// テスト用 Mock ERC20 トークン
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1_000_000 * 10**6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EscrowTest is Test {
    MultiSigERC20EscrowEIP712 public escrow;
    MockUSDC public token;

    uint256 internal payerPrivateKey = 0xA11CE;
    uint256 internal payeePrivateKey = 0xB0B;
    uint256 internal relayerPrivateKey = 0xCAFE;
    uint256 internal attackerPrivateKey = 0xBAD;

    address internal payer;
    address internal payee;
    address internal relayer;
    address internal attacker;

    bytes32 internal constant ALLOCATION_TYPEHASH = 
        keccak256("Allocation(address recipient,uint256 amount)");

    // deadline を除外した TYPEHASH
    bytes32 internal constant EXECUTE_TYPEHASH = 
        keccak256(
            "Execute(bytes32 escrowId,uint8 action,Allocation[] allocations)Allocation(address recipient,uint256 amount)"
        );

    function setUp() public {
        payer = vm.addr(payerPrivateKey);
        payee = vm.addr(payeePrivateKey);
        relayer = vm.addr(relayerPrivateKey);
        attacker = vm.addr(attackerPrivateKey);

        escrow = new MultiSigERC20EscrowEIP712();
        token = new MockUSDC();

        token.mint(payer, 1_000 * 10**6);
        vm.prank(payer);
        token.approve(address(escrow), type(uint256).max);
    }

    // --- 補助関数: EIP-712 署名の生成 ---
    function _signExecute(
        uint256 privateKey,
        bytes32 escrowId,
        MultiSigERC20EscrowEIP712.Action action,
        MultiSigERC20EscrowEIP712.Allocation[] memory allocations
    ) internal view returns (bytes memory) {
        bytes32[] memory allocHashes = new bytes32[](allocations.length);
        for (uint256 i = 0; i < allocations.length; i++) {
            allocHashes[i] = keccak256(
                abi.encode(ALLOCATION_TYPEHASH, allocations[i].recipient, allocations[i].amount)
            );
        }

        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_TYPEHASH,
                escrowId,
                action,
                keccak256(abi.encodePacked(allocHashes))
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _getDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ERC20EscrowSystem")),
                keccak256(bytes("1")),
                block.chainid,
                address(escrow)
            )
        );
    }

    // ==========================================
    //  正常系テスト (SUCCESS TESTS)
    // ==========================================

    // 1. 各自が順次 signExecute (オンチェーン) して2つの承認で実行されるテスト
    function test_Success_SequentialOnchainApprovals() public {
        bytes32 escrowId = bytes32("202609010001");
        uint256 amount = 100 * 10**6;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(payer);
        escrow.createEscrow(escrowId, payee, relayer, address(token), amount, deadline);

        MultiSigERC20EscrowEIP712.Allocation[] memory allocations = 
            new MultiSigERC20EscrowEIP712.Allocation[](1);
        allocations[0] = MultiSigERC20EscrowEIP712.Allocation({recipient: payee, amount: amount});

        // Payer の承認（1件目）
        vm.prank(payer);
        escrow.signExecute(escrowId, MultiSigERC20EscrowEIP712.Action.DONE, allocations);

        // まだ実行されていないことを確認
        (,,,,,,, bool isExecuted) = escrow.escrows(escrowId);
        assertFalse(isExecuted);

        // Relayer の承認（2件目 -> ここで自動実行）
        vm.prank(relayer);
        escrow.signExecute(escrowId, MultiSigERC20EscrowEIP712.Action.DONE, allocations);

        // 結果検証
        assertEq(token.balanceOf(payee), amount);
    }

    // 2. オフチェーン EIP-712 署名を1つずつ提出 (signExecuteBySig) して実行されるテスト
    function test_Success_SignBySigApprovals() public {
        bytes32 escrowId = bytes32("202609010002");
        uint256 amount = 100 * 10**6;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(payer);
        escrow.createEscrow(escrowId, payee, relayer, address(token), amount, deadline);

        MultiSigERC20EscrowEIP712.Allocation[] memory allocations = 
            new MultiSigERC20EscrowEIP712.Allocation[](1);
        allocations[0] = MultiSigERC20EscrowEIP712.Allocation({recipient: payee, amount: amount});

        // Payer と Payee の EIP-712 署名を生成
        bytes memory payerSig = _signExecute(payerPrivateKey, escrowId, MultiSigERC20EscrowEIP712.Action.DONE, allocations);
        bytes memory payeeSig = _signExecute(payeePrivateKey, escrowId, MultiSigERC20EscrowEIP712.Action.DONE, allocations);

        // 誰でも代行して署名を提出可能
        escrow.signExecuteBySig(escrowId, MultiSigERC20EscrowEIP712.Action.DONE, allocations, payerSig);
        escrow.signExecuteBySig(escrowId, MultiSigERC20EscrowEIP712.Action.DONE, allocations, payeeSig);

        assertEq(token.balanceOf(payee), amount);
    }

    // 3. Deadline 経過後に claimAfterDeadline で自動送金されるテスト
    function test_Success_ClaimAfterDeadline() public {
        bytes32 escrowId = bytes32("202609010003");
        uint256 amount = 100 * 10**6;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(payer);
        escrow.createEscrow(escrowId, payee, relayer, address(token), amount, deadline);

        // 時間を 2時間経過させる
        vm.warp(block.timestamp + 2 hours);

        // 第三者（attacker等）であっても呼び出し可能
        vm.prank(attacker);
        escrow.claimAfterDeadline(escrowId);

        // Payee に送金されたことを確認
        assertEq(token.balanceOf(payee), amount);
    }

    // ==========================================
    //  異常系テスト (REVERT TESTS)
    // ==========================================

    // 同一人物による二重承認の防止
    function test_Revert_WhenDuplicateApproval() public {
        bytes32 escrowId = bytes32("202609010004");
        uint256 amount = 100 * 10**6;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(payer);
        escrow.createEscrow(escrowId, payee, relayer, address(token), amount, deadline);

        MultiSigERC20EscrowEIP712.Allocation[] memory allocations = 
            new MultiSigERC20EscrowEIP712.Allocation[](1);
        allocations[0] = MultiSigERC20EscrowEIP712.Allocation({recipient: payee, amount: amount});

        vm.prank(payer);
        escrow.signExecute(escrowId, MultiSigERC20EscrowEIP712.Action.DONE, allocations);

        // Payer が再度同じ承認を行おうとするとリバート
        vm.prank(payer);
        vm.expectRevert("Already approved");
        escrow.signExecute(escrowId, MultiSigERC20EscrowEIP712.Action.DONE, allocations);
    }

    // 関係ない第三者の承認拒否
    function test_Revert_WhenUnauthorizedSigner() public {
        bytes32 escrowId = bytes32("202609010005");
        uint256 amount = 100 * 10**6;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(payer);
        escrow.createEscrow(escrowId, payee, relayer, address(token), amount, deadline);

        MultiSigERC20EscrowEIP712.Allocation[] memory allocations = 
            new MultiSigERC20EscrowEIP712.Allocation[](1);
        allocations[0] = MultiSigERC20EscrowEIP712.Allocation({recipient: payee, amount: amount});

        vm.prank(attacker);
        vm.expectRevert("Unauthorized signer");
        escrow.signExecute(escrowId, MultiSigERC20EscrowEIP712.Action.DONE, allocations);
    }

    // Deadline 前に claimAfterDeadline を呼ぶとリバート
    function test_Revert_WhenClaimBeforeDeadline() public {
        bytes32 escrowId = bytes32("202609010006");
        uint256 amount = 100 * 10**6;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(payer);
        escrow.createEscrow(escrowId, payee, relayer, address(token), amount, deadline);

        vm.expectRevert("Deadline not reached");
        escrow.claimAfterDeadline(escrowId);
    }
}