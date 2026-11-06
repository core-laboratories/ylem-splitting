// SPDX-License-Identifier: MIT
pragma solidity ^1.1.2;

import "spark-std/Test.sol";
import "openzeppelin-contracts/src/token/CRC20/CRC20.sol";
import "openzeppelin-contracts/src/utils/Checksum.sol";
import "../src/DistributeWithFee.sol";

contract MockCRC20 is CRC20 {
    constructor(address holder, uint256 amount) CRC20("Mock", "MOCK") {
        _mint(holder, amount);
    }
}

contract TaxedCRC20 is CRC20 {
    constructor(address holder, uint256 amount) CRC20("Taxed", "TAX") {
        _mint(holder, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        super._transfer(from, to, amount - 1);
        _burn(from, 1);
    }
}

contract RejectNative {
    receive() external payable {
        revert("Rejected");
    }
}

contract DistributeWithFeeTest is Test {
    DistributeWithFee internal distributor;
    MockCRC20 internal token;
    address internal sender;
    address internal treasury;
    address internal recipient;

    function setUp() public {
        sender = makeAddr("sender");
        treasury = makeAddr("treasury");
        recipient = makeAddr("recipient");
        distributor = new DistributeWithFee(treasury, 250);
        token = new MockCRC20(sender, 1_000);
        vm.deal(sender, 10 ether);
    }

    function testNativeTransferSplitsAmount() public {
        vm.prank(sender);
        distributor.transfer{value: 1 ether}(address(0), 1 ether, recipient);

        assertEq(treasury.balance, 0.025 ether);
        assertEq(recipient.balance, 0.975 ether);
        assertEq(address(distributor).balance, 0);
    }

    function testCRC20TransferSplitsAmount() public {
        vm.prank(sender);
        token.approve(address(distributor), 400);

        vm.prank(sender);
        distributor.transfer(address(token), 400, recipient);

        assertEq(token.balanceOf(sender), 600);
        assertEq(token.balanceOf(treasury), 10);
        assertEq(token.balanceOf(recipient), 390);
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    function testZeroAndFullFee() public {
        distributor.setFee(0);
        vm.prank(sender);
        distributor.transfer{value: 100}(address(0), 100, recipient);
        assertEq(treasury.balance, 0);
        assertEq(recipient.balance, 100);

        distributor.setFee(10_000);
        vm.prank(sender);
        token.approve(address(distributor), 100);
        vm.prank(sender);
        distributor.transfer(address(token), 100, recipient);
        assertEq(token.balanceOf(treasury), 100);
        assertEq(token.balanceOf(recipient), 0);
    }

    function testOnlyOwnerCanChangeSettings() public {
        address newTreasury = makeAddr("new treasury");
        distributor.setTreasury(newTreasury);
        distributor.setFee(10_000);
        assertEq(distributor.treasury(), newTreasury);
        assertEq(distributor.fee(), 10_000);

        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(sender);
        distributor.setTreasury(sender);

        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(sender);
        distributor.setFee(1);
    }

    function testRejectsInvalidSettingsAndAddresses() public {
        vm.expectRevert(bytes("Fee exceeds 10000 bps"));
        distributor.setFee(10_001);

        vm.expectRevert(bytes("Invalid treasury"));
        distributor.setTreasury(address(0));

        vm.expectRevert(bytes("Invalid treasury"));
        distributor.setTreasury(Checksum.zeroAddress());

        vm.expectRevert(bytes("Invalid treasury"));
        distributor.setTreasury(address(distributor));

        vm.expectRevert(bytes("Invalid recipient"));
        distributor.transfer(address(token), 1, address(0));

        vm.expectRevert(bytes("Invalid recipient"));
        distributor.transfer(address(token), 1, Checksum.zeroAddress());
    }

    function testRejectsMismatchedAssetAndValue() public {
        vm.expectRevert(bytes("Native amount mismatch"));
        distributor.transfer(address(0), 1, recipient);

        vm.expectRevert(bytes("Native amount mismatch"));
        distributor.transfer{value: 2}(address(0), 1, recipient);

        vm.expectRevert(bytes("Unexpected native value"));
        distributor.transfer{value: 1}(address(token), 1, recipient);

        vm.expectRevert(bytes("Invalid token"));
        distributor.transfer(Checksum.zeroAddress(), 1, recipient);

        vm.expectRevert(bytes("Zero amount"));
        distributor.transfer(address(token), 0, recipient);
    }

    function testNativeFailureRollsBackFeePayment() public {
        RejectNative rejectingRecipient = new RejectNative();

        vm.expectRevert(bytes("Native transfer failed"));
        vm.prank(sender);
        distributor.transfer{value: 1 ether}(address(0), 1 ether, address(rejectingRecipient));

        assertEq(treasury.balance, 0);
        assertEq(address(distributor).balance, 0);
    }

    function testTaxedInputCannotSpendExistingTokenBalance() public {
        TaxedCRC20 taxed = new TaxedCRC20(sender, 1_000);
        vm.prank(sender);
        taxed.approve(address(distributor), 100);

        vm.expectRevert(bytes("Incorrect token amount received"));
        vm.prank(sender);
        distributor.transfer(address(taxed), 100, recipient);

        assertEq(taxed.balanceOf(sender), 1_000);
        assertEq(taxed.balanceOf(treasury), 0);
        assertEq(taxed.balanceOf(recipient), 0);
    }

    function testRescueNativeAndTokensSkipsZeroBalancesAndDuplicates() public {
        vm.prank(sender);
        (bool received,) = address(distributor).call{value: 1 ether}("");
        assertTrue(received);

        vm.prank(sender);
        token.transfer(address(distributor), 200);
        MockCRC20 emptyToken = new MockCRC20(sender, 100);

        address[] memory tokens = new address[](5);
        tokens[0] = address(0);
        tokens[1] = address(token);
        tokens[2] = address(emptyToken);
        tokens[3] = address(token);
        tokens[4] = address(0);
        distributor.rescue(tokens);

        assertEq(treasury.balance, 1 ether);
        assertEq(token.balanceOf(treasury), 200);
        assertEq(address(distributor).balance, 0);
        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(emptyToken.balanceOf(treasury), 0);
    }

    function testOnlyOwnerCanRescue() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(sender);
        distributor.rescue(tokens);
    }

    function testRescueFailureLeavesFundsInContract() public {
        RejectNative rejectingTreasury = new RejectNative();
        distributor.setTreasury(address(rejectingTreasury));
        vm.deal(address(distributor), 1 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        vm.expectRevert(bytes("Native rescue failed"));
        distributor.rescue(tokens);

        assertEq(address(distributor).balance, 1 ether);
    }

    function testRescueRejectsChecksummedZeroToken() public {
        address[] memory tokens = new address[](1);
        tokens[0] = Checksum.zeroAddress();

        vm.expectRevert(bytes("Invalid token"));
        distributor.rescue(tokens);
    }
}
