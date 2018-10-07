pragma solidity ^0.4.24;

interface RepaymentRouter {
    function repay(
        bytes32 agreementId,
        uint256 amount,
        address tokenAddress
    )
        external
        returns (uint _amountRepaid);
}