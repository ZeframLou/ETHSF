pragma solidity ^0.4.24;

import "./dharma/DebtKernel.sol";
import "./dharma/RepaymentRouter.sol";
import "./dharma/TermsContract.sol";
import "./kyber/KyberNetworkProxyInterface.sol";
import "zeppelin/ownership/Ownable.sol";
import "zeppelin/math/SafeMath.sol";
import "./kyber/ERC20Interface.sol";

contract Portfolio is Ownable {
    using SafeMath for uint256;

    address public constant KYBER = 0x0;
    address public constant DEBT_KERNEL = 0x0;
    address public constant REPAYMENT_ROUTER = 0x0;
    uint256 public constant PRECISION = 10 ** 18;
    uint256 public constant MAX_AMOUNT = 10 ** 28;

    address public termsContractAddress;
    address public borrowedTokenAddress;
    address[] public assetList;
    uint256[] public fractionList;
    uint256[] public assetAmountList;
    bytes32 public agreementId;

    KyberNetworkProxyInterface public kyber;
    DebtKernal public debtKernel;
    RepaymentRouter public repaymentRouter;
    TermsContract public termsContract;

    ERC20 public borrowedToken;

    constructor (address[] _assetList, uint256[] _fractionList) public {
        assetList = _assetList;
        fractionList = _fractionList;

        kyber = KyberNetworkProxyInterface(KYBER);
        debtKernel = DebtKernel(DEBT_KERNEL);
        repaymentRouter = RepaymentRouter(REPAYMENT_ROUTER);
    }

    function startPortfolio(
        address creditor,
        address[6] orderAddresses,
        uint[8] orderValues,
        bytes32[1] orderBytes32,
        uint8[3] signaturesV,
        bytes32[3] signaturesR,
        bytes32[3] signaturesS
    ) public onlyOwner {
        if (termsContractAddress != address(0)) {
            // check if the previous loan has ended
            require(termsContract.getExpectedRepaymentValue(agreementId, termsContract.getTermEndTimestamp(agreementId)) == 0);
        }

        // initialize terms related contracts
        termsContractAddress = orderAddresses[3];
        termsContract = TermsContract(termsContractAddress);
        borrowedTokenAddress = orderAddresses[4];
        borrowedToken = ERC20(borrowedTokenAddress);

        // fill debt order and get funds
        uint256 beforeTokenBalance = borrowedToken.balanceOf(this);
        agreementId = debtKernel.fillDebtOrder(creditor, orderAddresses, orderValues, orderBytes32, signaturesV, signaturesR, signaturesS);

        // calculate received loan
        uint256 receivedLoan = borrowedToken.balanceOf(this).sub(beforeTokenBalance);

        // buy tokens using Kyber
        bytes memory hint;
        delete assetAmountList;
        for (uint256 i = 0; i < assetList.length; i++) {
            uint256 slippage;
            uint256 srcAmount = receivedLoan.mul(fractionList[i]).div(PRECISION);
            (,slippage) = getExpectedRate(borrowedToken, assetList[i], srcAmount);
            assetAmountList.push(tradeWithHint(borrowedToken, srcAmount, components[i], this, MAX_AMOUNT,
                slippage, 0, hint));
        }
    }
}