// SPDX-License-Identifier: MIT
pragma solidity ^1.1.2;

import "openzeppelin-contracts/src/access/Ownable.sol";
import "openzeppelin-contracts/src/token/CRC20/ICRC20.sol";
import "openzeppelin-contracts/src/token/CRC20/utils/SafeCRC20.sol";
import "openzeppelin-contracts/src/utils/Checksum.sol";

contract DistributeWithFee is Ownable {
    using SafeCRC20 for ICRC20;

    uint256 private constant BPS = 10_000;

    address public treasury;
    uint256 public fee;

    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event FeeUpdated(uint256 previousFee, uint256 newFee);
    event Distributed(address indexed sender, address indexed token, address indexed recipient, uint256 amount, uint256 feeAmount);
    event Rescued(address indexed token, uint256 amount);

    constructor(address initialTreasury, uint256 initialFee) {
        setTreasury(initialTreasury);
        setFee(initialFee);
    }

    receive() external payable {}

    function setTreasury(address newTreasury) public onlyOwner {
        require(
            newTreasury != address(0) && newTreasury != Checksum.zeroAddress() && newTreasury != address(this),
            "Invalid treasury"
        );
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setFee(uint256 newFee) public onlyOwner {
        require(newFee <= BPS, "Fee exceeds 10000 bps");
        emit FeeUpdated(fee, newFee);
        fee = newFee;
    }

    function transfer(address token, uint256 amount, address recipient) external payable {
        require(recipient != address(0) && recipient != Checksum.zeroAddress(), "Invalid recipient");
        require(amount != 0, "Zero amount");

        // Split without overflowing when amount is close to type(uint256).max.
        uint256 feeAmount = (amount / BPS) * fee + ((amount % BPS) * fee) / BPS;
        uint256 recipientAmount = amount - feeAmount;
        address feeRecipient = treasury;

        if (token == address(0)) {
            require(msg.value == amount, "Native amount mismatch");

            if (feeAmount != 0) {
                (bool feeSent,) = payable(feeRecipient).call{value: feeAmount}("");
                require(feeSent, "Native fee transfer failed");
            }
            if (recipientAmount != 0) {
                (bool recipientPaid,) = payable(recipient).call{value: recipientAmount}("");
                require(recipientPaid, "Native transfer failed");
            }
        } else {
            require(token != Checksum.zeroAddress(), "Invalid token");
            require(msg.value == 0, "Unexpected native value");

            ICRC20 asset = ICRC20(token);
            uint256 balanceBefore = asset.balanceOf(address(this));
            asset.safeTransferFrom(msg.sender, address(this), amount);
            require(asset.balanceOf(address(this)) == balanceBefore + amount, "Incorrect token amount received");

            if (feeAmount != 0) asset.safeTransfer(feeRecipient, feeAmount);
            if (recipientAmount != 0) asset.safeTransfer(recipient, recipientAmount);
        }

        emit Distributed(msg.sender, token, recipient, amount, feeAmount);
    }

    function rescue(address[] calldata tokens) external onlyOwner {
        address rescueRecipient = treasury;

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 balance;

            if (token == address(0)) {
                balance = address(this).balance;
                if (balance == 0) continue;

                (bool sent,) = payable(rescueRecipient).call{value: balance}("");
                require(sent, "Native rescue failed");
            } else {
                require(token != Checksum.zeroAddress(), "Invalid token");
                ICRC20 asset = ICRC20(token);
                balance = asset.balanceOf(address(this));
                if (balance == 0) continue;

                asset.safeTransfer(rescueRecipient, balance);
            }

            emit Rescued(token, balance);
        }
    }
}
