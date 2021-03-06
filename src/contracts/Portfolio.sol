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

    address public constant KYBER = 0x7e6b8b9510D71BF8EF0f893902EbB9C865eEF4Df;
    address public constant DEBT_KERNEL = 0x755e131019e5ab3e213dc269a4020e3e82e06e20;
    address public constant REPAYMENT_ROUTER = 0x0688659d5e36896da7e5d44ebe3e10aa9d2c9968;
    address public constant TERMS_CONTRACT = 0x4cad7ad79464628c07227928c851d3bc5ef3da0c;
    address public constant DAI_ADDRESS = 0x8870946B0018E2996a7175e8380eb0d43dD09EFE; // actually OMG, same for demo purposes
    address public constant TOKEN_PROXY = 0x668beab2e4dfec1d8c0a70fb5e52987cb22c2f1a;
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
    uint256 public collateralInDAI;
    bytes32 public agreementId;
    bool public hasStarted;

    KyberNetworkProxyInterface public kyber;
    DebtKernel public debtKernel;
    RepaymentRouter public repaymentRouter;
    TermsContract public termsContract;

    ERC20 public borrowedToken;
    ERC20 public dai;

    constructor (address[] _assetList, uint256[] _fractionList, uint256 _collateralInDAI) public {
        assetList = _assetList;
        fractionList = _fractionList;
        collateralInDAI = _collateralInDAI;

        kyber = KyberNetworkProxyInterface(KYBER);
        debtKernel = DebtKernel(DEBT_KERNEL);
        repaymentRouter = RepaymentRouter(REPAYMENT_ROUTER);
        termsContract = TermsContract(TERMS_CONTRACT);
        dai = ERC20(DAI_ADDRESS);
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

        require(orderAddresses[1] == owner); // debtor == owner

        // transfer collateral
        require(dai.transferFrom(owner, this, collateralInDAI));

        // initialize contracts
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
            borrowedToken.approve(KYBER, srcAmount);
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
        uint256 amountRepaid;
        uint256 amountToRepay;
        

        // sell all assets into the token owed to the creditor
        for (uint256 i = 0; i < assetList.length; i++) {
            uint256 slippage;
            (, slippage) = kyber.getExpectedRate(ERC20(assetList[i]), borrowedToken, assetAmountList[i]);
            ERC20(assetList[i]).approve(KYBER, assetAmountList[i]);
            kyber.tradeWithHint(ERC20(assetList[i]), assetAmountList[i], borrowedToken, this, MAX_AMOUNT, slippage, 0, hint);
        }

        // pay back loan
        amountToRepay = termsContract.getExpectedRepaymentValue(agreementId, termsContract.getTermEndTimestamp(agreementId));
        borrowedToken.approve(TOKEN_PROXY, amountToRepay);
        
        if (amountToRepay <= borrowedToken.balanceOf(this)) {
            // have enough to repay
            amountRepaid = repaymentRouter.repay(
                agreementId,
                amountToRepay,
                creditorAddress);
            require(amountRepaid > 0);

            // send leftover tokens to owner
            borrowedToken.transfer(owner, borrowedToken.balanceOf(this));
            dai.transfer(owner, dai.balanceOf(this));
            return amountRepaid;
        }
        
        // don't have enough to repay loan, sell collateral
        (, slippage) = kyber.getExpectedRate(dai, borrowedToken, collateralInDAI);
        uint256 daiToConvert = PRECISION.mul(amountToRepay.sub(borrowedToken.balanceOf(this))).div(slippage);
        
        if (daiToConvert > collateralInDAI) {
            // collateral not enough to repay loan
            daiToConvert = collateralInDAI;
        }

        // sell collateral
        (, slippage) = kyber.getExpectedRate(dai, borrowedToken, daiToConvert);
        dai.approve(KYBER, daiToConvert);
        kyber.tradeWithHint(dai, daiToConvert, borrowedToken, this, MAX_AMOUNT, slippage, 0, hint);

        // repay loan
        borrowedToken.approve(TOKEN_PROXY, amountToRepay);
        amountRepaid = repaymentRouter.repay(agreementId, amountToRepay, creditorAddress);
        require(amountRepaid > 0);

        // send leftover tokens to owner
        borrowedToken.transfer(owner, dai.balanceOf(this));
        dai.transfer(owner, dai.balanceOf(this));
        return amountRepaid;
    }
}