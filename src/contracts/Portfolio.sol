pragma solidity ^0.4.24;

import "./dharma/DebtKernel.sol";
import "./dharma/RepaymentRouter.sol";
import "./dharma/TermsContract.sol";
import "./kyber/KyberNetworkProxyInterface.sol";
import "./kyber/ERC20Interface.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";

contract Portfolio is Ownable {
    using SafeMath for uint256;

    address public constant KYBER = 0x0;
    address public constant DEBT_KERNEL = 0x0;
    address public constant REPAYMENT_ROUTER = 0x0;
    address public constant TERMS_CONTRACT = 0x0;
    uint256 public constant PRECISION = 10 ** 18;
    uint256 public constant MAX_AMOUNT = 10 ** 28;

    address public termsContractAddress;
    address public borrowedTokenAddress;

    address public creditorAddress;

    // holds the list of assets the manager wants to invest in
    address[] public assetList; 

    // holds the list of proportions that each asset takes in the portfolio
    uint256[] public fractionList;

    // holds the amount of the assets the user chose to invest in
    uint256[] public assetAmountList;
    bytes32 public agreementId;
    bool public hasStarted;

    KyberNetworkProxyInterface public kyber;
    DebtKernel public debtKernel;
    RepaymentRouter public repaymentRouter;
    TermsContract public termsContract;

    ERC20 public borrowedToken;

    constructor (address[] _assetList, uint256[] _fractionList) public {
        assetList = _assetList;
        fractionList = _fractionList;

        kyber = KyberNetworkProxyInterface(KYBER);
        debtKernel = DebtKernel(DEBT_KERNEL);
        repaymentRouter = RepaymentRouter(REPAYMENT_ROUTER);
        termsContract = TermsContract(TERMS_CONTRACT);
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
        require(!hasStarted);
        hasStarted = true;

        // initialize terms related contracts
        termsContractAddress = orderAddresses[3];
        termsContract = TermsContract(termsContractAddress);
        borrowedTokenAddress = orderAddresses[4];
        borrowedToken = ERC20(borrowedTokenAddress);
        creditorAddress = creditor;

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
            (,slippage) = kyber.getExpectedRate(borrowedToken, ERC20(assetList[i]), srcAmount);
            assetAmountList.push(kyber.tradeWithHint(borrowedToken, srcAmount, ERC20(assetList[i]), this, MAX_AMOUNT,
                slippage, 0, hint));
        }
    }

    function endPortfolio() public returns (uint256 _amountRepaid) {
        // check if the amount to repay is > 0 and the time is between loan called and loan end period
        require(
            termsContract.getExpectedRepaymentValue(agreementId, termsContract.getTermEndTimestamp(agreementId)) != 0 && 
            now <= termsContract.getTermEndTimestamp(agreementId)
        );
        
        bytes memory hint;
        uint256 amountRedeemed;
        uint256 amountRepaid;

        // sell all assets into the token owed to the creditor
        for (uint256 i = 0; i < assetList.length; i++) {
            uint256 slippage;
            (, slippage) = kyber.getExpectedRate(ERC20(assetList[i]), borrowedToken, assetAmountList[i]);
            amountRedeemed = amountRedeemed.add(kyber.tradeWithHint(ERC20(assetList[i]), assetAmountList[i], borrowedToken, this, MAX_AMOUNT, slippage, 0, hint));
        }

        // if redeemed amount is enough to pay the creditor, pay the creditor the owed amount and pay the debtor the excess
        amountRepaid = repaymentRouter.repay(
            agreementId,
            termsContract.getExpectedRepaymentValue(agreementId, termsContract.getTermEndTimestamp(agreementId)),
            creditorAddress);

        // pay the debtor the excess amount
        borrowedToken.transfer(owner, borrowedToken.balanceOf(owner));
        return amountRepaid;
    }
}