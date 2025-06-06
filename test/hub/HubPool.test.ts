import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import {
  HubMockPool__factory,
  HubPoolLogic__factory,
  HubPoolLogged__factory,
  MockOracleManager__factory,
  HubMockPool,
} from "../../typechain-types";
import { getInitialPoolData, PoolData } from "./libraries/assets/poolData";
import {
  BYTES32_LENGTH,
  UINT256_LENGTH,
  convertEVMAddressToGenericAddress,
  convertGenericAddressToEVMAddress,
  convertNumberToBytes,
  convertStringToBytes,
  getAccountIdBytes,
  getEmptyBytes,
  getRandomAddress,
} from "../utils/bytes";
import { SECONDS_IN_DAY, SECONDS_IN_HOUR, SECONDS_IN_YEAR, getLatestBlockTimestamp, getRandomInt } from "../utils/time";
import { Action, Finality, MessageParams, buildMessagePayload, extraArgsToBytes } from "../utils/messages/messages";
import { getNodeOutputData } from "./libraries/assets/oracleData";
import {
  calcAverageStableBorrowInterestRate,
  calcBorrowInterestIndex,
  calcDepositInterestIndex,
  calcDepositInterestRate,
  calcFlashLoanFeeAmount,
  calcLiquidatorAverageStableRate,
  calcOverallBorrowInterestRate,
  calcRebalanceDownThreshold,
  calcRebalanceUpThreshold,
  calcStableBorrowInterestRate,
  calcStableDebtToTotalDebtRatio,
  calcTotalDebt,
  calcUtilisationRatio,
  calcVariableBorrowInterestRate,
  toFAmount,
  toUnderlingAmount,
} from "./utils/formulae";
import { ONE_14_DP, ONE_18_DP, mulScale } from "./utils/mathLib";

describe("HubPool (unit tests)", () => {
  const DEFAULT_ADMIN_ROLE = getEmptyBytes(BYTES32_LENGTH);
  const PARAM_ROLE = ethers.keccak256(convertStringToBytes("PARAM"));
  const ORACLE_ROLE = ethers.keccak256(convertStringToBytes("ORACLE"));
  const HUB_ROLE = ethers.keccak256(convertStringToBytes("HUB"));
  const LOAN_MANAGER_ROLE = ethers.keccak256(convertStringToBytes("LOAN_MANAGER"));

  const ethDecimals = 18;

  const verifyInterestRates = async (hubPool: HubMockPool) => {
    const [, rr] = await hubPool.getFeeData();
    const [our, dta, dir] = await hubPool.getDepositData();
    const [vr0, vr1, vr2, vbta, vbir] = await hubPool.getVariableBorrowData();
    const [sr0, sr1, sr2, sr3, osttdr, , , , sbta, sbir, asbir] = await hubPool.getStableBorrowData();

    const td = calcTotalDebt(vbta, sbta);
    const ur = calcUtilisationRatio(td, dta);
    const variableBorrowInterestRate = calcVariableBorrowInterestRate(vr0, vr1, vr2, ur, our);
    const sdttdr = calcStableDebtToTotalDebtRatio(sbta, td);
    const stableBorrowInterestRate = calcStableBorrowInterestRate(vr1, sr0, sr1, sr2, sr3, ur, our, sdttdr, osttdr);
    const obir = calcOverallBorrowInterestRate(vbta, sbta, variableBorrowInterestRate, asbir);
    const depositInterestRate = calcDepositInterestRate(ur, obir, rr);

    expect(vbir).to.equal(variableBorrowInterestRate);
    expect(sbir).to.equal(stableBorrowInterestRate);
    expect(dir).to.equal(depositInterestRate);
  };

  async function deployHubPoolFixture() {
    const [admin, hub, loanManager, user, ...unusedUsers] = await ethers.getSigners();

    // libraries
    const hubPoolLogic = await new HubPoolLogic__factory(user).deploy();
    const hubPoolLogicAddress = await hubPoolLogic.getAddress();

    // deploy contract
    const tokenDecimals = 18;
    const tsTokenName = "townSq Ether";
    const tsTokenSymbol = "fETH";
    const poolId = 1;
    const initialPoolData = getInitialPoolData();
    const oracleManager = await new MockOracleManager__factory(user).deploy();
    const hubPool = await new HubMockPool__factory(
      {
        "contracts/hub/logic/HubPoolLogic.sol:HubPoolLogic": hubPoolLogicAddress,
      },
      user
    ).deploy(
      admin,
      hub,
      loanManager,
      tokenDecimals,
      tsTokenName,
      tsTokenSymbol,
      poolId,
      initialPoolData,
      oracleManager
    );

    // common
    const hubPoolAddress = await hubPool.getAddress();

    return {
      admin,
      hub,
      loanManager,
      user,
      unusedUsers,
      hubPool,
      hubPoolAddress,
      hubPoolLogicAddress,
      tokenDecimals,
      tsTokenName,
      tsTokenSymbol,
      poolId,
      initialPoolData,
      oracleManager,
    };
  }

  describe("Deployment", () => {
    it("Should set admin and contracts correctly", async () => {
      const {
        admin,
        hub,
        loanManager,
        tokenDecimals,
        tsTokenName,
        tsTokenSymbol,
        hubPool,
        poolId,
        initialPoolData,
        oracleManager,
      } = await loadFixture(deployHubPoolFixture);

      // check default admin role
      expect(await hubPool.owner()).to.equal(admin.address);
      expect(await hubPool.defaultAdmin()).to.equal(admin.address);
      expect(await hubPool.defaultAdminDelay()).to.equal(SECONDS_IN_DAY);
      expect(await hubPool.getRoleAdmin(DEFAULT_ADMIN_ROLE)).to.equal(DEFAULT_ADMIN_ROLE);
      expect(await hubPool.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;

      // check other roles
      expect(await hubPool.getRoleAdmin(PARAM_ROLE)).to.equal(DEFAULT_ADMIN_ROLE);
      expect(await hubPool.hasRole(PARAM_ROLE, admin.address)).to.be.true;
      expect(await hubPool.getRoleAdmin(ORACLE_ROLE)).to.equal(DEFAULT_ADMIN_ROLE);
      expect(await hubPool.hasRole(ORACLE_ROLE, admin.address)).to.be.true;
      expect(await hubPool.getRoleAdmin(HUB_ROLE)).to.equal(DEFAULT_ADMIN_ROLE);
      expect(await hubPool.hasRole(HUB_ROLE, hub.address)).to.be.true;
      expect(await hubPool.getRoleAdmin(LOAN_MANAGER_ROLE)).to.equal(DEFAULT_ADMIN_ROLE);
      expect(await hubPool.hasRole(LOAN_MANAGER_ROLE, loanManager.address)).to.be.true;

      // check state - HubPoolState
      const latestBlockTimestamp = await getLatestBlockTimestamp();
      expect(await hubPool.poolId()).to.equal(poolId);
      expect(await hubPool.getLastUpdateTimestamp()).to.equal(latestBlockTimestamp);
      expect(await hubPool.getFeeData()).to.deep.equal(Object.values(initialPoolData.feeData));
      expect(await hubPool.getDepositData()).to.deep.equal(Object.values(initialPoolData.depositData));
      expect(await hubPool.getVariableBorrowData()).to.deep.equal(Object.values(initialPoolData.variableBorrowData));
      expect(await hubPool.getStableBorrowData()).to.deep.equal(Object.values(initialPoolData.stableBorrowData));
      expect(await hubPool.getCapsData()).to.deep.equal(Object.values(initialPoolData.capsData));
      expect(await hubPool.getConfigData()).to.deep.equal(Object.values(initialPoolData.configData));
      expect(await hubPool.getOracleManager()).to.equal(oracleManager);

      // check state - HubPool
      expect(await hubPool.getPoolId()).to.equal(poolId);
      expect(await hubPool.getTokenFeeClaimer()).to.equal(initialPoolData.feeData.tokenFeeClaimer);
      expect(await hubPool.getTokenFeeRecipient()).to.deep.equal(initialPoolData.feeData.tokenFeeRecipient);
      expect(await hubPool.decimals()).to.equal(tokenDecimals);
      expect(await hubPool.name()).to.equal(tsTokenName);
      expect(await hubPool.symbol()).to.equal(tsTokenSymbol);
    });
  });

  describe("Clear Token Fees", () => {
    it("Should successfully clear token fees", async () => {
      const { hub, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data with token fees
      const poolData = getInitialPoolData();
      const depositTotalAmount = BigInt(10e18);
      const stableBorrowTotalAmount = BigInt(0.5e18);
      const feeTotalRetainedAmount = BigInt(4.15e18);
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.feeData.totalRetainedAmount = feeTotalRetainedAmount;
      await hubPool.setPoolData(poolData);

      // clear token fees
      const clearTokenFees = await hubPool.connect(hub).clearTokenFees();
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPool);
      expect((await hubPool.getDepositData())[1]).to.equal(depositTotalAmount - feeTotalRetainedAmount);
      expect((await hubPool.getFeeData())[4]).to.equal(0);
      await expect(clearTokenFees).to.emit(hubPoolLogic, "ClearTokenFees").withArgs(feeTotalRetainedAmount);
      await verifyInterestRates(hubPool);
    });

    it("Should fail to clear token fees when insufficient liquidity", async () => {
      const { hub, hubPool, hubPoolLogicAddress } = await loadFixture(deployHubPoolFixture);

      // set pool data with token fees
      const poolData = getInitialPoolData();
      const feeTotalRetainedAmount = BigInt(4.15e18);
      poolData.feeData.totalRetainedAmount = feeTotalRetainedAmount;
      await hubPool.setPoolData(poolData);

      // clear token fees when insufficient liquidity
      poolData.depositData.totalAmount = feeTotalRetainedAmount - BigInt(1);
      await hubPool.setPoolData(poolData);
      const clearTokenFees = hubPool.connect(hub).clearTokenFees();
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(clearTokenFees).to.be.revertedWithCustomError(hubPoolLogic, "InsufficientLiquidity");

      // clear token fees when liquidity okay
      poolData.depositData.totalAmount = feeTotalRetainedAmount;
      await hubPool.setPoolData(poolData);
      await hubPool.connect(hub).clearTokenFees();
    });

    it("Should fail to clear token fees when sender is not hub", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // clear token fees
      const clearTokenFees = hubPool.connect(user).clearTokenFees();
      await expect(clearTokenFees)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, HUB_ROLE);
    });
  });

  describe("Verify Receive Token", () => {
    it("Should successfully verify receive token", async () => {
      const { hubPool } = await loadFixture(deployHubPoolFixture);

      // add chain spoke
      const chainId = 1;
      const spokeAddress = convertEVMAddressToGenericAddress(getRandomAddress());
      await hubPool.addChainSpoke(chainId, spokeAddress);

      // verify receive token
      await hubPool.verifyReceiveToken(chainId, spokeAddress);
    });

    it("Should fail to verify receive token when no spoke on given chain", async () => {
      const { hubPool } = await loadFixture(deployHubPoolFixture);

      // don't add chain spoke
      const chainId = 1;
      const spokeAddress = convertEVMAddressToGenericAddress(getRandomAddress());

      // verify receive token
      const verifyReceiveToken = hubPool.verifyReceiveToken(chainId, spokeAddress);
      await expect(verifyReceiveToken).to.be.revertedWithCustomError(hubPool, "NoChainSpoke").withArgs(chainId);
    });

    it("Should fail to verify receive token when spoke on given chain doesn't match", async () => {
      const { hubPool } = await loadFixture(deployHubPoolFixture);

      // add chain spoke
      const chainId = 1;
      const spokeAddress = convertEVMAddressToGenericAddress(getRandomAddress());
      await hubPool.addChainSpoke(chainId, spokeAddress);

      // verify receive token
      const unknownSpokeAddress = convertEVMAddressToGenericAddress(getRandomAddress());
      const verifyReceiveToken = hubPool.verifyReceiveToken(chainId, unknownSpokeAddress);
      await expect(verifyReceiveToken)
        .to.be.revertedWithCustomError(hubPool, "UnmatchedChainSpoke")
        .withArgs(chainId, unknownSpokeAddress, spokeAddress);
    });
  });

  describe("Get Send Token Message", () => {
    it("Should successfully get send token message", async () => {
      const { admin, user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy mock hub so can emit event with message
      const hub = await new HubPoolLogged__factory(user).deploy(hubPool);
      const hubAddress = await hub.getAddress();
      await hubPool.connect(admin).grantRole(HUB_ROLE, hub);

      // add chain spoke
      const chainId = 1;
      const spokeAddress = convertEVMAddressToGenericAddress(getRandomAddress());
      await hubPool.addChainSpoke(chainId, spokeAddress);

      // set extra args
      const amount = BigInt(0.1e18);
      const extraArgs = extraArgsToBytes(getRandomAddress(), getRandomAddress(), amount);
      await hubPool.setExtraArgs(extraArgs);

      // get send token message
      const bridgeRouter = getRandomAddress();
      const adapterId = BigInt(2);
      const gasLimit = BigInt(30000);
      const accountId = getAccountIdBytes("ACCOUNT_ID");
      const recipient = convertEVMAddressToGenericAddress(getRandomAddress());
      const getSendTokenMessage = await hub.getSendTokenMessage(
        bridgeRouter,
        adapterId,
        gasLimit,
        accountId,
        chainId,
        amount,
        recipient
      );

      // verify message
      const MESSAGE_PARAMS: MessageParams = {
        adapterId,
        returnAdapterId: BigInt(0),
        receiverValue: BigInt(0),
        gasLimit,
        returnGasLimit: BigInt(0),
      };
      const payload = buildMessagePayload(
        Action.SendToken,
        accountId,
        convertGenericAddressToEVMAddress(recipient),
        convertNumberToBytes(amount, UINT256_LENGTH)
      );
      await expect(getSendTokenMessage)
        .to.emit(hubPool, "SendToken")
        .withArgs(bridgeRouter, spokeAddress, Object.values(MESSAGE_PARAMS), amount);
      await expect(getSendTokenMessage)
        .to.emit(hub, "SendMessage")
        .withArgs(
          Object.values(MESSAGE_PARAMS),
          convertEVMAddressToGenericAddress(hubAddress),
          chainId,
          spokeAddress,
          payload,
          Finality.FINALISED,
          extraArgs
        );
    });

    it("Should fail to get send token message when no spoke on given chain", async () => {
      const { hub, hubPool } = await loadFixture(deployHubPoolFixture);

      // don't add chain spoke
      const chainId = 1;

      // get send token message
      const bridgeRouter = getRandomAddress();
      const adapterId = BigInt(2);
      const gasLimit = BigInt(30000);
      const accountId = getAccountIdBytes("ACCOUNT_ID");
      const amount = BigInt(0.1e18);
      const recipient = convertEVMAddressToGenericAddress(getRandomAddress());
      const getSendTokenMessage = hubPool
        .connect(hub)
        .getSendTokenMessage(bridgeRouter, adapterId, gasLimit, accountId, chainId, amount, recipient);
      await expect(getSendTokenMessage).to.be.revertedWithCustomError(hubPool, "NoChainSpoke").withArgs(chainId);
    });

    it("Should fail to get send token message when sender is not hub", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // add chain spoke
      const chainId = 1;
      const spokeAddress = convertEVMAddressToGenericAddress(getRandomAddress());
      await hubPool.addChainSpoke(chainId, spokeAddress);

      // get send token message
      const bridgeRouter = getRandomAddress();
      const adapterId = BigInt(2);
      const gasLimit = BigInt(30000);
      const accountId = getAccountIdBytes("ACCOUNT_ID");
      const amount = BigInt(0.1e18);
      const recipient = convertEVMAddressToGenericAddress(getRandomAddress());
      const getSendTokenMessage = hubPool
        .connect(user)
        .getSendTokenMessage(bridgeRouter, adapterId, gasLimit, accountId, chainId, amount, recipient);
      await expect(getSendTokenMessage)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, HUB_ROLE);
    });
  });

  describe("Get Updated Deposit Interest Index", () => {
    it("Should successfully get updated deposit interest index", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy hub pool logged can emit return value
      const hubPoolLogged = await new HubPoolLogged__factory(user).deploy(hubPool);

      // set pool data with interest data
      const lastUpdateTimestamp = BigInt(await getLatestBlockTimestamp());
      const poolData = getInitialPoolData();
      const depositInterestRate = BigInt(0.07302374549e18);
      const depositInterestIndex = BigInt(1.4933745843e18);
      poolData.depositData.interestRate = depositInterestRate;
      poolData.depositData.interestIndex = depositInterestIndex;
      poolData.lastUpdateTimestamp = lastUpdateTimestamp;
      await hubPool.setPoolData(poolData);

      // simulate interest over time period
      const timestamp = lastUpdateTimestamp + BigInt(getRandomInt(SECONDS_IN_HOUR));
      await time.setNextBlockTimestamp(timestamp);
      const newDepositInterestIndex = calcDepositInterestIndex(
        depositInterestRate,
        depositInterestIndex,
        timestamp - lastUpdateTimestamp,
        true
      );

      // get updated deposit interest index
      const getUpdatedDepositInterestIndex = await hubPoolLogged.getUpdatedDepositInterestIndex();
      await expect(getUpdatedDepositInterestIndex)
        .to.emit(hubPoolLogged, "InterestIndex")
        .withArgs(newDepositInterestIndex);
    });
  });

  describe("Get Updated Variable Borrow Interest Index", () => {
    it("Should successfully get updated variable borrow interest index", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy hub pool logged can emit return value
      const hubPoolLogged = await new HubPoolLogged__factory(user).deploy(hubPool);

      // set pool data with interest data
      const lastUpdateTimestamp = BigInt(await getLatestBlockTimestamp());
      const poolData = getInitialPoolData();
      const borrowInterestRate = BigInt(0.14938285295e18);
      const borrowInterestIndex = BigInt(1.1394253233e18);
      poolData.variableBorrowData.interestRate = borrowInterestRate;
      poolData.variableBorrowData.interestIndex = borrowInterestIndex;
      poolData.lastUpdateTimestamp = lastUpdateTimestamp;
      await hubPool.setPoolData(poolData);

      // simulate interest over time period
      const timestamp = lastUpdateTimestamp + BigInt(getRandomInt(SECONDS_IN_YEAR));
      await time.setNextBlockTimestamp(timestamp);
      const newVariableBorrowInterestIndex = calcBorrowInterestIndex(
        borrowInterestRate,
        borrowInterestIndex,
        timestamp - lastUpdateTimestamp,
        true
      );

      // get updated variable borrow interest index
      const getUpdatedVariableBorrowInterestIndex = await hubPoolLogged.getUpdatedVariableBorrowInterestIndex();
      await expect(getUpdatedVariableBorrowInterestIndex)
        .to.emit(hubPoolLogged, "InterestIndex")
        .withArgs(newVariableBorrowInterestIndex);
    });
  });

  describe("Update Interest Indexes", () => {
    it("Should successfully update interest indexes", async () => {
      const { hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data with interest data
      const lastUpdateTimestamp = BigInt(await getLatestBlockTimestamp());
      const poolData = getInitialPoolData();
      const depositInterestRate = BigInt(0.00148372358e18);
      const depositInterestIndex = BigInt(1.0e18);
      const borrowInterestRate = BigInt(0.048330237577e18);
      const borrowInterestIndex = BigInt(1.0e18);
      poolData.depositData.interestRate = depositInterestRate;
      poolData.depositData.interestIndex = depositInterestIndex;
      poolData.lastUpdateTimestamp = lastUpdateTimestamp;
      poolData.variableBorrowData.interestRate = borrowInterestRate;
      poolData.variableBorrowData.interestIndex = borrowInterestIndex;
      poolData.lastUpdateTimestamp = lastUpdateTimestamp;
      await hubPool.setPoolData(poolData);

      // simulate interest over time period
      const timestamp = lastUpdateTimestamp + BigInt(getRandomInt(SECONDS_IN_YEAR));
      await time.setNextBlockTimestamp(timestamp);
      const newDepositInterestIndex = calcDepositInterestIndex(
        depositInterestRate,
        depositInterestIndex,
        timestamp - lastUpdateTimestamp,
        true
      );
      const newVariableBorrowInterestIndex = calcBorrowInterestIndex(
        borrowInterestRate,
        borrowInterestIndex,
        timestamp - lastUpdateTimestamp,
        true
      );

      // update interest indexes
      const updateInterestIndexes = await hubPool.updateInterestIndexes();
      expect((await hubPool.getDepositData())[3]).to.equal(newDepositInterestIndex);
      expect((await hubPool.getVariableBorrowData())[5]).to.equal(newVariableBorrowInterestIndex);
      await expect(updateInterestIndexes)
        .to.emit(hubPool, "InterestIndexesUpdated")
        .withArgs(newVariableBorrowInterestIndex, newDepositInterestIndex, timestamp);
    });
  });

  describe("Update Pool With Deposit", () => {
    it("Should successfully update pool with deposit", async () => {
      const { admin, user, hubPool, oracleManager, poolId } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set pool data with deposit interest index
      const depositInterestIndex = BigInt(1.839232023893e18);
      const poolData = getInitialPoolData();
      poolData.depositData.interestIndex = depositInterestIndex;
      await hubPool.setPoolData(poolData);

      // set price
      const ethNodeOutputData = getNodeOutputData(BigInt(1000e18));
      await oracleManager.setNodeOutput(poolId, ethDecimals, ethNodeOutputData);

      // update pool with deposit
      const amount = BigInt(0.1e18);
      const updatePoolWithDeposit = await loanManager.updatePoolWithDeposit(amount);
      expect((await hubPool.getDepositData())[1]).to.equal(poolData.depositData.totalAmount + amount);
      await expect(updatePoolWithDeposit).to.emit(hubPool, "InterestIndexesUpdated");
      await expect(updatePoolWithDeposit).to.emit(hubPool, "InterestRatesUpdated");
      await expect(updatePoolWithDeposit)
        .to.emit(loanManager, "DepositPoolParams")
        .withArgs([
          toFAmount(amount, depositInterestIndex),
          depositInterestIndex,
          [ethNodeOutputData.price, ethDecimals],
        ]);
      await verifyInterestRates(hubPool);
    });

    it("Should fail to update pool with deposit when pool is deprecated", async () => {
      const { admin, loanManager, hubPool, hubPoolLogicAddress } = await loadFixture(deployHubPoolFixture);

      // set pool to be deprecated
      const configData = {
        deprecated: true,
        stableBorrowSupported: true,
        canMintTsToken: true,
        flashLoanSupported: true,
      };
      await hubPool.connect(admin).updateConfigData(configData);

      // update pool with deposit
      const amount = BigInt(0.1e18);
      const updatePoolWithDeposit = hubPool.connect(loanManager).updatePoolWithDeposit(amount);
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(updatePoolWithDeposit).to.be.revertedWithCustomError(hubPoolLogic, "DeprecatedPool");
    });

    it("Should fail to update pool with deposit when deposit cap is reached", async () => {
      const { loanManager, hubPool, hubPoolLogicAddress, oracleManager, poolId } =
        await loadFixture(deployHubPoolFixture);

      // set pool data with deposit cap $1000
      const depositCap = BigInt(1000);
      const poolData = getInitialPoolData();
      poolData.capsData.deposit = depositCap;
      await hubPool.setPoolData(poolData);

      // set price
      const ethNodeOutputData = getNodeOutputData(BigInt(1000e18));
      await oracleManager.setNodeOutput(poolId, ethDecimals, ethNodeOutputData);

      // update pool with deposit when deposit cap exceeded
      let amount = BigInt(1.0000001e18);
      const updatePoolWithDeposit = hubPool.connect(loanManager).updatePoolWithDeposit(amount);
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(updatePoolWithDeposit).to.be.revertedWithCustomError(hubPoolLogic, "DepositCapReached");

      // update pool with deposit when deposit cap okay
      amount = BigInt(1e18);
      await hubPool.connect(loanManager).updatePoolWithDeposit(amount);
    });

    it("Should fail to update pool with deposit when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // update pool with deposit
      const amount = BigInt(1);
      const updatePoolWithDeposit = hubPool.connect(user).updatePoolWithDeposit(amount);
      await expect(updatePoolWithDeposit)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Prepare Pool For Withdraw", () => {
    it("Should successfully prepare pool for withdraw token when not f amount", async () => {
      const { admin, user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set pool data with deposit interest index and deposit total amount
      const depositInterestIndex = BigInt(1.839232023893e18);
      const depositTotalAmount = BigInt(10e18);
      const poolData = getInitialPoolData();
      poolData.depositData.interestIndex = depositInterestIndex;
      poolData.depositData.totalAmount = depositTotalAmount;
      await hubPool.setPoolData(poolData);

      // calculate amounts
      const amount = BigInt(0.15e18);
      const isFAmount = false;
      const fAmount = toFAmount(amount, depositInterestIndex, true);

      // prepare pool for withdraw
      const preparePoolForWithdraw = await loanManager.preparePoolForWithdraw(amount, isFAmount);
      await expect(preparePoolForWithdraw).to.emit(hubPool, "InterestIndexesUpdated");
      await expect(preparePoolForWithdraw).to.emit(loanManager, "WithdrawPoolParams").withArgs([amount, fAmount]);
    });

    it("Should successfully update pool with withdraw when 1 amount", async () => {
      const { admin, user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set pool data with deposit interest index and deposit total amount
      const depositInterestIndex = BigInt(1.839232023893e18);
      const depositTotalAmount = BigInt(10e18);
      const poolData = getInitialPoolData();
      poolData.depositData.interestIndex = depositInterestIndex;
      poolData.depositData.totalAmount = depositTotalAmount;
      await hubPool.setPoolData(poolData);

      // calculate amounts
      const amount = BigInt(1);
      const isFAmount = false;
      const fAmount = BigInt(1);

      // prepare pool for withdraw
      const preparePoolForWithdraw = await loanManager.preparePoolForWithdraw(amount, isFAmount);
      await expect(preparePoolForWithdraw).to.emit(hubPool, "InterestIndexesUpdated");
      await expect(preparePoolForWithdraw).to.emit(loanManager, "WithdrawPoolParams").withArgs([amount, fAmount]);
    });

    it("Should successfully prepare pool for withdraw token when is f amount", async () => {
      const { admin, user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set pool data with deposit interest index and deposit total amount
      const depositInterestIndex = BigInt(1.839232023893e18);
      const depositTotalAmount = BigInt(10e18);
      const poolData = getInitialPoolData();
      poolData.depositData.interestIndex = depositInterestIndex;
      poolData.depositData.totalAmount = depositTotalAmount;
      await hubPool.setPoolData(poolData);

      // calculate amounts
      const amount = BigInt(0.0357235345e18);
      const isFAmount = true;
      const underlingAmount = toUnderlingAmount(amount, depositInterestIndex);

      // prepare pool for withdraw
      const preparePoolForWithdraw = await loanManager.preparePoolForWithdraw(amount, isFAmount);
      await expect(preparePoolForWithdraw).to.emit(hubPool, "InterestIndexesUpdated");
      await expect(preparePoolForWithdraw)
        .to.emit(loanManager, "WithdrawPoolParams")
        .withArgs([underlingAmount, amount]);
    });

    it("Should fail to prepare pool for withdraw when insufficient liquidity", async () => {
      const { loanManager, hubPool, hubPoolLogicAddress } = await loadFixture(deployHubPoolFixture);

      // set pool data with deposit and debt data
      const depositInterestIndex = BigInt(1.839232023893e18);
      const depositTotalAmount = BigInt(10e18);
      const variableBorrowTotalAmount = BigInt(5e18);
      const stableBorrowTotalAmount = BigInt(4e18);
      const available = depositTotalAmount - (variableBorrowTotalAmount + stableBorrowTotalAmount);
      const poolData = getInitialPoolData();
      poolData.depositData.interestIndex = depositInterestIndex;
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.variableBorrowData.totalAmount = variableBorrowTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      await hubPool.setPoolData(poolData);

      // prepare pool for withdraw when insufficient liquidity
      let amount = available + BigInt(1);
      const isFAmount = false;
      const preparePoolForWithdraw = hubPool.connect(loanManager).preparePoolForWithdraw(amount, isFAmount);
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(preparePoolForWithdraw).to.be.revertedWithCustomError(hubPoolLogic, "InsufficientLiquidity");

      // prepare pool for withdraw when liquidity okay
      amount = available;
      await hubPool.connect(loanManager).preparePoolForWithdraw(amount, isFAmount);
    });

    it("Should fail to prepare pool for withdraw when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // update pool with withdraw
      const amount = BigInt(0.15e18);
      const isFAmount = false;
      const updatePoolWithWithdraw = hubPool.connect(user).preparePoolForWithdraw(amount, isFAmount);
      await expect(updatePoolWithWithdraw)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Update Pool With Withdraw", () => {
    it("Should successfully update pool with withdraw", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data with deposit interest index and deposit total amount
      const depositInterestIndex = BigInt(1.839232023893e18);
      const depositTotalAmount = BigInt(10e18);
      const poolData = getInitialPoolData();
      poolData.depositData.interestIndex = depositInterestIndex;
      poolData.depositData.totalAmount = depositTotalAmount;
      await hubPool.setPoolData(poolData);

      // update pool with withdraw
      const underlyingAmount = BigInt(0.15e18);
      const updatePoolWithWithdraw = await hubPool.connect(loanManager).updatePoolWithWithdraw(underlyingAmount);
      expect((await hubPool.getDepositData())[1]).to.equal(depositTotalAmount - underlyingAmount);
      await expect(updatePoolWithWithdraw).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should fail to update pool with withdraw when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // update pool with withdraw
      const underlyingAmount = BigInt(0.15e18);
      const updatePoolWithWithdraw = hubPool.connect(user).updatePoolWithWithdraw(underlyingAmount);
      await expect(updatePoolWithWithdraw)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Prepare Pool For Withdraw TS Token", () => {
    it("Should successfully prepare pool for withdraw ts token", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // prepare pool for withdraw ts token
      await hubPool.connect(loanManager).preparePoolForWithdrawTsToken();
    });

    it("Should fail to prepare pool for withdraw ts token when pool is deprecated", async () => {
      const { admin, loanManager, hubPool, hubPoolLogicAddress } = await loadFixture(deployHubPoolFixture);

      // set pool to be deprecated
      const configData = {
        deprecated: true,
        stableBorrowSupported: true,
        canMintTsToken: true,
        flashLoanSupported: true,
      };
      await hubPool.connect(admin).updateConfigData(configData);

      // prepare pool for withdraw ts token
      const preparePoolForWithdrawTsToken = hubPool.connect(loanManager).preparePoolForWithdrawTsToken();
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(preparePoolForWithdrawTsToken).to.be.revertedWithCustomError(hubPoolLogic, "DeprecatedPool");
    });

    it("Should fail to prepare pool for withdraw ts token when cannot mint ts token", async () => {
      const { admin, loanManager, hubPool, hubPoolLogicAddress } = await loadFixture(deployHubPoolFixture);

      // set pool to cannot mint ts token
      const configData = {
        deprecated: false,
        stableBorrowSupported: true,
        canMintTsToken: false,
        flashLoanSupported: true,
      };
      await hubPool.connect(admin).updateConfigData(configData);

      // prepare pool for withdraw ts token
      const preparePoolForWithdrawTsToken = hubPool.connect(loanManager).preparePoolForWithdrawTsToken();
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(preparePoolForWithdrawTsToken).to.be.revertedWithCustomError(hubPoolLogic, "CannotMintTsToken");
    });

    it("Should fail to prepare pool for withdraw ts token when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // prepare pool for withdraw ts token
      const preparePoolForWithdrawTsToken = hubPool.connect(user).preparePoolForWithdrawTsToken();
      await expect(preparePoolForWithdrawTsToken)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Prepare Pool For Borrow", () => {
    it("Should successfully prepare pool for variable borrow", async () => {
      const { admin, user, hubPool, oracleManager, poolId } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set price
      const ethNodeOutputData = getNodeOutputData(BigInt(1000e18));
      await oracleManager.setNodeOutput(poolId, ethDecimals, ethNodeOutputData);

      // set pool data with interest data
      const lastUpdateTimestamp = BigInt(await getLatestBlockTimestamp());
      const depositTotalAmount = BigInt(1e18);
      const borrowInterestRate = BigInt(0.048330237577e18);
      const borrowInterestIndex = BigInt(1.1394253233e18);
      const stableBorrowInterestRate = BigInt(0.14329e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.variableBorrowData.interestRate = borrowInterestRate;
      poolData.variableBorrowData.interestIndex = borrowInterestIndex;
      poolData.stableBorrowData.interestRate = stableBorrowInterestRate;
      poolData.lastUpdateTimestamp = lastUpdateTimestamp;
      await hubPool.setPoolData(poolData);

      // simulate interest over time period
      const timestamp = lastUpdateTimestamp + BigInt(getRandomInt(SECONDS_IN_DAY));
      await time.setNextBlockTimestamp(timestamp);
      const newVariableBorrowInterestIndex = calcBorrowInterestIndex(
        borrowInterestRate,
        borrowInterestIndex,
        timestamp - lastUpdateTimestamp,
        true
      );

      // prepare pool for borrow
      const amount = BigInt(0.1e18);
      const maxStableRate = 0;
      const preparePoolForBorrow = await loanManager.preparePoolForBorrow(amount, maxStableRate);
      await expect(preparePoolForBorrow).to.emit(hubPool, "InterestIndexesUpdated");
      await expect(preparePoolForBorrow)
        .to.emit(loanManager, "BorrowPoolParams")
        .withArgs([newVariableBorrowInterestIndex, stableBorrowInterestRate]);
    });

    it("Should successfully prepare pool for stable borrow", async () => {
      const { admin, user, hubPool, oracleManager, poolId } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set price
      const ethNodeOutputData = getNodeOutputData(BigInt(1000e18));
      await oracleManager.setNodeOutput(poolId, ethDecimals, ethNodeOutputData);

      // set pool data with interest data
      const lastUpdateTimestamp = BigInt(await getLatestBlockTimestamp());
      const depositTotalAmount = BigInt(100e18);
      const borrowInterestRate = BigInt(0.048330237577e18);
      const borrowInterestIndex = BigInt(1.1394253233e18);
      const stableBorrowInterestRate = BigInt(0.14329e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.variableBorrowData.interestRate = borrowInterestRate;
      poolData.variableBorrowData.interestIndex = borrowInterestIndex;
      poolData.stableBorrowData.interestRate = stableBorrowInterestRate;
      poolData.lastUpdateTimestamp = lastUpdateTimestamp;
      await hubPool.setPoolData(poolData);

      // simulate interest over time period
      const timestamp = lastUpdateTimestamp + BigInt(getRandomInt(SECONDS_IN_DAY));
      await time.setNextBlockTimestamp(timestamp);
      const newVariableBorrowInterestIndex = calcBorrowInterestIndex(
        borrowInterestRate,
        borrowInterestIndex,
        timestamp - lastUpdateTimestamp,
        true
      );

      // prepare pool for borrow
      const amount = BigInt(0.1e18);
      const maxStableRate = stableBorrowInterestRate;
      const preparePoolForBorrow = await loanManager.preparePoolForBorrow(amount, maxStableRate);
      await expect(preparePoolForBorrow).to.emit(hubPool, "InterestIndexesUpdated");
      await expect(preparePoolForBorrow)
        .to.emit(loanManager, "BorrowPoolParams")
        .withArgs([newVariableBorrowInterestIndex, stableBorrowInterestRate]);
    });

    it("Should fail to prepare pool for borrow when pool is deprecated", async () => {
      const { admin, loanManager, hubPool, hubPoolLogicAddress } = await loadFixture(deployHubPoolFixture);

      // set pool to be deprecated
      const configData = {
        deprecated: true,
        stableBorrowSupported: true,
        canMintTsToken: true,
        flashLoanSupported: true,
      };
      await hubPool.connect(admin).updateConfigData(configData);

      // prepare pool for borrow
      const amount = BigInt(1);
      const maxStableRate = BigInt(0);
      const preparePoolForBorrow = hubPool.connect(loanManager).preparePoolForBorrow(amount, maxStableRate);
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(preparePoolForBorrow).to.be.revertedWithCustomError(hubPoolLogic, "DeprecatedPool");
    });

    it("Should fail to prepare pool for borrow when insufficient liquidity", async () => {
      const { loanManager, hubPool, hubPoolLogicAddress, oracleManager, poolId } =
        await loadFixture(deployHubPoolFixture);

      // set price
      const ethNodeOutputData = getNodeOutputData(BigInt(1000e18));
      await oracleManager.setNodeOutput(poolId, ethDecimals, ethNodeOutputData);

      // set pool data with deposit and debt data
      const depositTotalAmount = BigInt(10e18);
      const variableBorrowTotalAmount = BigInt(5e18);
      const stableBorrowTotalAmount = BigInt(4e18);
      const available = depositTotalAmount - (variableBorrowTotalAmount + stableBorrowTotalAmount);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.variableBorrowData.totalAmount = variableBorrowTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      await hubPool.setPoolData(poolData);

      // prepare pool for borrow when insufficient liquidity
      let amount = available + BigInt(1);
      const maxStableRate = 0;
      const preparePoolForBorrow = hubPool.connect(loanManager).preparePoolForBorrow(amount, maxStableRate);
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(preparePoolForBorrow).to.be.revertedWithCustomError(hubPoolLogic, "InsufficientLiquidity");

      // prepare pool for borrow when liquidity okay
      amount = available;
      await hubPool.connect(loanManager).preparePoolForBorrow(amount, maxStableRate);
    });

    it("Should fail to prepare pool for borrow when stable borrow not supported", async () => {
      const { admin, loanManager, hubPool, hubPoolLogicAddress } = await loadFixture(deployHubPoolFixture);

      // set pool data with deposit data
      const depositTotalAmount = BigInt(10e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      await hubPool.setPoolData(poolData);

      // set pool to not support stable borrow
      const configData = {
        deprecated: false,
        stableBorrowSupported: false,
        canMintTsToken: true,
        flashLoanSupported: true,
      };
      await hubPool.connect(admin).updateConfigData(configData);

      // prepare pool for borrow when stable borrow
      const amount = BigInt(1);
      let maxStableRate = poolData.stableBorrowData.interestRate;
      const preparePoolForBorrow = hubPool.connect(loanManager).preparePoolForBorrow(amount, maxStableRate);
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(preparePoolForBorrow).to.be.revertedWithCustomError(hubPoolLogic, "StableBorrowNotSupported");

      // prepare pool for borrow when variable borrow
      maxStableRate = BigInt(0);
      await hubPool.connect(loanManager).preparePoolForBorrow(amount, maxStableRate);
    });

    it("Should fail to prepare pool for borrow when borrow cap exceeded", async () => {
      const { loanManager, hubPool, hubPoolLogicAddress, oracleManager, poolId } =
        await loadFixture(deployHubPoolFixture);

      // set price
      const ethNodeOutputData = getNodeOutputData(BigInt(1000e18));
      await oracleManager.setNodeOutput(poolId, ethDecimals, ethNodeOutputData);

      // set pool data with interest data
      const depositTotalAmount = BigInt(10e18);
      const borrowCap = BigInt(1000);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.capsData.borrow = borrowCap;
      await hubPool.setPoolData(poolData);

      // prepare pool for borrow when borrow cap exceeded
      let amount = BigInt(1e18) + BigInt(1);
      const maxStableRate = 0;
      const preparePoolForBorrow = hubPool.connect(loanManager).preparePoolForBorrow(amount, maxStableRate);
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(preparePoolForBorrow).to.be.revertedWithCustomError(hubPoolLogic, "BorrowCapReached");

      // prepare pool for borrow when borrow cap okay
      amount = BigInt(1e18);
      await hubPool.connect(loanManager).preparePoolForBorrow(amount, maxStableRate);
    });

    it("Should fail to prepare pool for borrow when stable borrow cap exceeded", async () => {
      const { loanManager, hubPool, hubPoolLogicAddress, oracleManager, poolId } =
        await loadFixture(deployHubPoolFixture);

      // set price
      const ethNodeOutputData = getNodeOutputData(BigInt(1000e18));
      await oracleManager.setNodeOutput(poolId, ethDecimals, ethNodeOutputData);

      // set pool data with interest data
      const depositTotalAmount = BigInt(1e18);
      const stableBorrowPercentageCap = BigInt(0.1e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.capsData.stableBorrowPercentage = stableBorrowPercentageCap;
      await hubPool.setPoolData(poolData);

      // prepare pool for borrow when max stable rate exceeded
      let amount = mulScale(depositTotalAmount, stableBorrowPercentageCap, ONE_18_DP) + BigInt(1);
      const maxStableRate = poolData.stableBorrowData.interestRate;
      const preparePoolForBorrow = hubPool.connect(loanManager).preparePoolForBorrow(amount, maxStableRate);
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(preparePoolForBorrow).to.be.revertedWithCustomError(
        hubPoolLogic,
        "StableBorrowPercentageCapExceeded"
      );

      // prepare pool for borrow when max stable rate okay
      amount -= BigInt(1);
      await hubPool.connect(loanManager).preparePoolForBorrow(amount, maxStableRate);
    });

    it("Should fail to prepare pool for borrow when max stable rate exceeded", async () => {
      const { loanManager, hubPool, hubPoolLogicAddress, oracleManager, poolId } =
        await loadFixture(deployHubPoolFixture);

      // set price
      const ethNodeOutputData = getNodeOutputData(BigInt(1000e18));
      await oracleManager.setNodeOutput(poolId, ethDecimals, ethNodeOutputData);

      // set pool data with deposit total amount
      const depositTotalAmount = BigInt(100e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      await hubPool.setPoolData(poolData);

      // prepare pool for borrow when max stable rate exceeded
      const amount = BigInt(0.1e18);
      let maxStableRate = poolData.stableBorrowData.interestRate - BigInt(1);
      const preparePoolForBorrow = hubPool.connect(loanManager).preparePoolForBorrow(amount, maxStableRate);
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(preparePoolForBorrow)
        .to.be.revertedWithCustomError(hubPoolLogic, "MaxStableRateExceeded")
        .withArgs(poolData.stableBorrowData.interestRate, maxStableRate);

      // prepare pool for borrow when max stable rate okay
      maxStableRate = poolData.stableBorrowData.interestRate;
      await hubPool.connect(loanManager).preparePoolForBorrow(amount, maxStableRate);
    });

    it("Should fail to prepare pool for borrow when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // prepare pool for borrow
      const amount = BigInt(1);
      const maxStableRate = BigInt(0);
      const preparePoolForBorrow = hubPool.connect(user).preparePoolForBorrow(amount, maxStableRate);
      await expect(preparePoolForBorrow)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Update Pool With Borrow", () => {
    it("Should successfully update pool with variable borrow", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data with deposit total amount
      const depositTotalAmount = BigInt(10e18);
      const variableBorrowTotalAmount = BigInt(1.43543539e18);
      const poolData = getInitialPoolData();
      poolData.variableBorrowData.totalAmount = variableBorrowTotalAmount;
      poolData.depositData.totalAmount = depositTotalAmount;
      await hubPool.setPoolData(poolData);

      // update pool with borrow
      const oldBorrowAmount = BigInt(0.2e8);
      const additionalBorrowAmount = BigInt(0.1e8);
      const oldBorrowStableRate = BigInt(0);
      const newBorrowStableRate = BigInt(0);
      const isStable = false;
      const updatePoolWithBorrow = await hubPool
        .connect(loanManager)
        .updatePoolWithBorrow(
          oldBorrowAmount,
          additionalBorrowAmount,
          oldBorrowStableRate,
          newBorrowStableRate,
          isStable
        );
      expect((await hubPool.getVariableBorrowData())[3]).to.equal(variableBorrowTotalAmount + additionalBorrowAmount);
      await expect(updatePoolWithBorrow).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should successfully update pool with stable borrow when no old borrow amount", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data with interest data
      const depositTotalAmount = BigInt(10e18);
      const stableBorrowTotalAmount = BigInt(1e18);
      const stableInterestRate = BigInt(0.2e18);
      const stableAverageInterestRate = BigInt(0.1e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.interestRate = stableInterestRate;
      poolData.stableBorrowData.averageInterestRate = stableAverageInterestRate;
      await hubPool.setPoolData(poolData);

      // calculate new stable average interest rate
      const oldBorrowAmount = BigInt(0);
      const additionalBorrowAmount = BigInt(1e18);
      const oldBorrowStableRate = BigInt(0);
      const newBorrowStableRate = stableInterestRate;
      const newStableAverageInterestRate = calcAverageStableBorrowInterestRate(
        oldBorrowAmount,
        oldBorrowAmount + additionalBorrowAmount,
        oldBorrowStableRate,
        newBorrowStableRate,
        stableBorrowTotalAmount,
        stableAverageInterestRate
      );

      // update pool with borrow
      const isStable = true;
      const updatePoolWithBorrow = await hubPool
        .connect(loanManager)
        .updatePoolWithBorrow(
          oldBorrowAmount,
          additionalBorrowAmount,
          oldBorrowStableRate,
          newBorrowStableRate,
          isStable
        );
      expect((await hubPool.getStableBorrowData())[8]).to.equal(stableBorrowTotalAmount + additionalBorrowAmount);
      expect((await hubPool.getStableBorrowData())[10]).to.equal(newStableAverageInterestRate);
      await expect(updatePoolWithBorrow).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should successfully update pool with stable borrow when there is an old borrow amount", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data with interest data
      const depositTotalAmount = BigInt(10e18);
      const stableBorrowTotalAmount = BigInt(1e18);
      const stableInterestRate = BigInt(0.2e18);
      const stableAverageInterestRate = BigInt(0.1e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.interestRate = stableInterestRate;
      poolData.stableBorrowData.averageInterestRate = stableAverageInterestRate;
      await hubPool.setPoolData(poolData);

      // calculate new stable average interest rate
      const oldBorrowAmount = BigInt(0.25e18);
      const additionalBorrowAmount = BigInt(0.5e18);
      const oldBorrowStableRate = stableAverageInterestRate;
      const newBorrowStableRate = stableInterestRate;
      const newStableAverageInterestRate = calcAverageStableBorrowInterestRate(
        oldBorrowAmount,
        oldBorrowAmount + additionalBorrowAmount,
        oldBorrowStableRate,
        newBorrowStableRate,
        stableBorrowTotalAmount,
        stableAverageInterestRate
      );

      // update pool with borrow
      const isStable = true;
      const updatePoolWithBorrow = await hubPool
        .connect(loanManager)
        .updatePoolWithBorrow(
          oldBorrowAmount,
          additionalBorrowAmount,
          oldBorrowStableRate,
          newBorrowStableRate,
          isStable
        );
      expect((await hubPool.getStableBorrowData())[8]).to.equal(stableBorrowTotalAmount + additionalBorrowAmount);
      expect((await hubPool.getStableBorrowData())[10]).to.equal(newStableAverageInterestRate);
      await expect(updatePoolWithBorrow).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should fail to update pool with borrow when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // prepare pool for borrow
      const oldBorrowAmount = BigInt(0);
      const additionalBorrowAmount = BigInt(1);
      const oldBorrowStableRate = BigInt(0);
      const newBorrowStableRate = BigInt(0);
      const isStable = false;
      const updatePoolWithBorrow = hubPool
        .connect(user)
        .updatePoolWithBorrow(
          oldBorrowAmount,
          additionalBorrowAmount,
          oldBorrowStableRate,
          newBorrowStableRate,
          isStable
        );
      await expect(updatePoolWithBorrow)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Prepare Pool For Repay", () => {
    it("Should successfully prepare pool for repay", async () => {
      const { admin, user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set pool data with interest data
      const lastUpdateTimestamp = BigInt(await getLatestBlockTimestamp());
      const borrowInterestRate = BigInt(0.048330237577e18);
      const borrowInterestIndex = BigInt(1.1394253233e18);
      const stableBorrowInterestRate = BigInt(0.14329e18);
      const poolData = getInitialPoolData();
      poolData.variableBorrowData.interestRate = borrowInterestRate;
      poolData.variableBorrowData.interestIndex = borrowInterestIndex;
      poolData.stableBorrowData.interestRate = stableBorrowInterestRate;
      poolData.lastUpdateTimestamp = lastUpdateTimestamp;
      await hubPool.setPoolData(poolData);

      // simulate interest over time period
      const timestamp = lastUpdateTimestamp + BigInt(getRandomInt(SECONDS_IN_DAY));
      await time.setNextBlockTimestamp(timestamp);
      const newVariableBorrowInterestIndex = calcBorrowInterestIndex(
        borrowInterestRate,
        borrowInterestIndex,
        timestamp - lastUpdateTimestamp,
        true
      );

      // prepare pool for repay
      const preparePoolForRepay = await loanManager.preparePoolForRepay();
      await expect(preparePoolForRepay).to.emit(hubPool, "InterestIndexesUpdated");
      await expect(preparePoolForRepay)
        .to.emit(loanManager, "BorrowPoolParams")
        .withArgs([newVariableBorrowInterestIndex, stableBorrowInterestRate]);
    });

    it("Should fail to prepare pool for repay when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // prepare pool for repay
      const preparePoolForRepay = hubPool.connect(user).preparePoolForRepay();
      await expect(preparePoolForRepay)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Update Pool With Repay", () => {
    it("Should successfully update pool with repay of variable borrow", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data
      const depositTotalAmount = BigInt(10e18);
      const variableBorrowTotalAmount = BigInt(1.43543539e18);
      const feeTotalRetainedAmount = BigInt(0.14e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.variableBorrowData.totalAmount = variableBorrowTotalAmount;
      poolData.feeData.totalRetainedAmount = feeTotalRetainedAmount;
      await hubPool.setPoolData(poolData);

      // update pool with repay
      const principalPaid = BigInt(1.4e8);
      const interestPaid = BigInt(0.09811e8);
      const loanStableRate = BigInt(0);
      const excessAmount = BigInt(0.0023e18);
      const updatePoolWithRepay = await hubPool
        .connect(loanManager)
        .updatePoolWithRepay(principalPaid, interestPaid, loanStableRate, excessAmount);
      expect((await hubPool.getVariableBorrowData())[3]).to.equal(
        poolData.variableBorrowData.totalAmount - principalPaid
      );
      expect((await hubPool.getFeeData())[4]).to.equal(feeTotalRetainedAmount + excessAmount);
      expect((await hubPool.getDepositData())[1]).to.equal(depositTotalAmount + interestPaid + excessAmount);
      await expect(updatePoolWithRepay).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should successfully update pool with repay of stable borrow", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data
      const depositTotalAmount = BigInt(10e18);
      const stableBorrowTotalAmount = BigInt(1.43543539e18);
      const stableInterestRate = BigInt(0.1420009e18);
      const stableAverageInterestRate = BigInt(0.19014e18);
      const feeTotalRetainedAmount = BigInt(0.14e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.interestRate = stableInterestRate;
      poolData.stableBorrowData.averageInterestRate = stableAverageInterestRate;
      poolData.feeData.totalRetainedAmount = feeTotalRetainedAmount;
      await hubPool.setPoolData(poolData);

      // calculate new stable average interest rate
      const principalPaid = BigInt(1.4e8);
      const loanStableRate = BigInt(0.125e18);
      const newStableAverageInterestRate = calcAverageStableBorrowInterestRate(
        principalPaid,
        BigInt(0),
        loanStableRate,
        loanStableRate,
        stableBorrowTotalAmount,
        stableAverageInterestRate
      );

      // update pool with repay
      const interestPaid = BigInt(0.09811e8);
      const excessAmount = BigInt(0.0023e18);
      const updatePoolWithRepay = await hubPool
        .connect(loanManager)
        .updatePoolWithRepay(principalPaid, interestPaid, loanStableRate, excessAmount);
      expect((await hubPool.getStableBorrowData())[8]).to.equal(poolData.stableBorrowData.totalAmount - principalPaid);
      expect((await hubPool.getStableBorrowData())[10]).to.equal(newStableAverageInterestRate);
      expect((await hubPool.getFeeData())[4]).to.equal(feeTotalRetainedAmount + excessAmount);
      expect((await hubPool.getDepositData())[1]).to.equal(depositTotalAmount + interestPaid + excessAmount);
      await expect(updatePoolWithRepay).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should handle underflow of stable average interest rate", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data
      const depositTotalAmount = BigInt(10e18);
      const stableBorrowTotalAmount = BigInt(2.386376e6);
      const stableInterestRate = BigInt(0.12e18);
      const stableAverageInterestRate = BigInt(0.107852660268122039e18);
      const feeTotalRetainedAmount = BigInt(0.14e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.interestRate = stableInterestRate;
      poolData.stableBorrowData.averageInterestRate = stableAverageInterestRate;
      poolData.feeData.totalRetainedAmount = feeTotalRetainedAmount;
      await hubPool.setPoolData(poolData);

      // calculate new stable average interest rate
      const principalPaid = stableBorrowTotalAmount - BigInt(1);
      const loanStableRate = BigInt(0.107852785437925392e18);
      const newStableAverageInterestRate = calcAverageStableBorrowInterestRate(
        principalPaid,
        BigInt(0),
        loanStableRate,
        loanStableRate,
        stableBorrowTotalAmount,
        stableAverageInterestRate
      );

      // update pool with repay
      const interestPaid = BigInt(0);
      const excessAmount = BigInt(0);
      const updatePoolWithRepay = await hubPool
        .connect(loanManager)
        .updatePoolWithRepay(principalPaid, interestPaid, loanStableRate, excessAmount);
      expect((await hubPool.getStableBorrowData())[8]).to.equal(poolData.stableBorrowData.totalAmount - principalPaid);
      expect((await hubPool.getStableBorrowData())[10]).to.equal(newStableAverageInterestRate);
      expect((await hubPool.getFeeData())[4]).to.equal(feeTotalRetainedAmount + excessAmount);
      expect((await hubPool.getDepositData())[1]).to.equal(depositTotalAmount + interestPaid);
      await expect(updatePoolWithRepay).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should fail to update pool with repay when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // update pool with repay
      const principalPaid = BigInt(1.4e8);
      const interestPaid = BigInt(0.09811e8);
      const loanStableRate = BigInt(0);
      const excessAmount = BigInt(0.0023e18);
      const updatePoolWithRepay = hubPool
        .connect(user)
        .updatePoolWithRepay(principalPaid, interestPaid, loanStableRate, excessAmount);
      await expect(updatePoolWithRepay)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Update Pool With Repay With Collateral", () => {
    it("Should successfully update pool with repay with collateral of variable borrow", async () => {
      const { admin, user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set pool data
      const depositInterestIndex = BigInt(1.839232023893e18);
      const depositTotalAmount = BigInt(10e18);
      const variableBorrowTotalAmount = BigInt(1.43543539e18);
      const feeTotalRetainedAmount = BigInt(0.14e18);
      const poolData = getInitialPoolData();
      poolData.depositData.interestIndex = depositInterestIndex;
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.variableBorrowData.totalAmount = variableBorrowTotalAmount;
      poolData.feeData.totalRetainedAmount = feeTotalRetainedAmount;
      await hubPool.setPoolData(poolData);

      // update pool with repay with collateral
      const principalPaid = BigInt(1.4e8);
      const interestPaid = BigInt(0.09811e8);
      const loanStableRate = BigInt(0);
      const updatePoolWithRepayWithCollateral = await loanManager.updatePoolWithRepayWithCollateral(
        principalPaid,
        interestPaid,
        loanStableRate
      );
      expect((await hubPool.getVariableBorrowData())[3]).to.equal(
        poolData.variableBorrowData.totalAmount - principalPaid
      );
      expect((await hubPool.getDepositData())[1]).to.equal(depositTotalAmount - principalPaid);
      await expect(updatePoolWithRepayWithCollateral).to.emit(hubPool, "InterestRatesUpdated");
      await expect(updatePoolWithRepayWithCollateral)
        .to.emit(loanManager, "RepayWithCollateralPoolParams")
        .withArgs([toFAmount(principalPaid + interestPaid, depositInterestIndex, true)]);
      await verifyInterestRates(hubPool);
    });

    it("Should successfully update pool with repay with collateral of stable borrow", async () => {
      const { admin, user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set pool data
      const depositInterestIndex = BigInt(1.839232023893e18);
      const depositTotalAmount = BigInt(10e18);
      const stableBorrowTotalAmount = BigInt(1.43543539e18);
      const stableInterestRate = BigInt(0.1420009e18);
      const stableAverageInterestRate = BigInt(0.19014e18);
      const feeTotalRetainedAmount = BigInt(0.14e18);
      const poolData = getInitialPoolData();
      poolData.depositData.interestIndex = depositInterestIndex;
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.interestRate = stableInterestRate;
      poolData.stableBorrowData.averageInterestRate = stableAverageInterestRate;
      poolData.feeData.totalRetainedAmount = feeTotalRetainedAmount;
      await hubPool.setPoolData(poolData);

      // calculate new stable average interest rate
      const principalPaid = BigInt(1.4e8);
      const loanStableRate = BigInt(0.125e18);
      const newStableAverageInterestRate = calcAverageStableBorrowInterestRate(
        principalPaid,
        BigInt(0),
        loanStableRate,
        loanStableRate,
        stableBorrowTotalAmount,
        stableAverageInterestRate
      );

      // update pool with repay with collateral
      const interestPaid = BigInt(0.09811e8);
      const updatePoolWithRepayWithCollateral = await loanManager.updatePoolWithRepayWithCollateral(
        principalPaid,
        interestPaid,
        loanStableRate
      );
      expect((await hubPool.getStableBorrowData())[8]).to.equal(poolData.stableBorrowData.totalAmount - principalPaid);
      expect((await hubPool.getStableBorrowData())[10]).to.equal(newStableAverageInterestRate);
      expect((await hubPool.getDepositData())[1]).to.equal(depositTotalAmount - principalPaid);
      await expect(updatePoolWithRepayWithCollateral).to.emit(hubPool, "InterestRatesUpdated");
      await expect(updatePoolWithRepayWithCollateral)
        .to.emit(loanManager, "RepayWithCollateralPoolParams")
        .withArgs([toFAmount(principalPaid + interestPaid, depositInterestIndex, true)]);
      await verifyInterestRates(hubPool);
    });

    it("Should successfully update pool with repay with collateral when 1 amount", async () => {
      const { admin, user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set pool data
      const depositInterestIndex = BigInt(1.839232023893e18);
      const depositTotalAmount = BigInt(10e18);
      const variableBorrowTotalAmount = BigInt(1.43543539e18);
      const feeTotalRetainedAmount = BigInt(0.14e18);
      const poolData = getInitialPoolData();
      poolData.depositData.interestIndex = depositInterestIndex;
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.variableBorrowData.totalAmount = variableBorrowTotalAmount;
      poolData.feeData.totalRetainedAmount = feeTotalRetainedAmount;
      await hubPool.setPoolData(poolData);

      // update pool with repay with collateral
      const principalPaid = BigInt(0);
      const interestPaid = BigInt(1);
      const loanStableRate = BigInt(0);
      const updatePoolWithRepayWithCollateral = await loanManager.updatePoolWithRepayWithCollateral(
        principalPaid,
        interestPaid,
        loanStableRate
      );
      expect((await hubPool.getVariableBorrowData())[3]).to.equal(
        poolData.variableBorrowData.totalAmount - principalPaid
      );
      expect((await hubPool.getDepositData())[1]).to.equal(depositTotalAmount - principalPaid);
      await expect(updatePoolWithRepayWithCollateral).to.emit(hubPool, "InterestRatesUpdated");
      await expect(updatePoolWithRepayWithCollateral)
        .to.emit(loanManager, "RepayWithCollateralPoolParams")
        .withArgs([BigInt(1)]);
      await verifyInterestRates(hubPool);
    });

    it("Should fail to update pool with repay with collateral when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // update pool with repay with collateral
      const principalPaid = BigInt(1.4e8);
      const interestPaid = BigInt(0.09811e8);
      const loanStableRate = BigInt(0);
      const updatePoolWithRepayWithCollateral = hubPool
        .connect(user)
        .updatePoolWithRepayWithCollateral(principalPaid, interestPaid, loanStableRate);
      await expect(updatePoolWithRepayWithCollateral)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Update Pool With Liquidation", () => {
    it("Should successfully update pool with liquidation when variable borrow", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data with interest data
      const depositTotalAmount = BigInt(10e18);
      const variableBorrowTotalAmount = BigInt(1.43543539e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.variableBorrowData.totalAmount = variableBorrowTotalAmount;
      await hubPool.setPoolData(poolData);

      // update pool with liquidation
      const repaidBorrowAmount = BigInt(0.35e18);
      const violatorLoanStableRate = BigInt(0);
      const liquidatorOldBorrowAmount = BigInt(0.4e18);
      const liquidatorOldLoanStableRate = BigInt(0);
      const liquidatorNewLoanStableRate = BigInt(0);
      const updatePoolWithLiquidation = await hubPool
        .connect(loanManager)
        .updatePoolWithLiquidation(
          repaidBorrowAmount,
          violatorLoanStableRate,
          liquidatorOldBorrowAmount,
          liquidatorOldLoanStableRate,
          liquidatorNewLoanStableRate
        );
      await expect(updatePoolWithLiquidation).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should successfully update pool with liquidation when stable borrow and no existing liquidator borrow", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data with interest data
      const depositTotalAmount = BigInt(10e18);
      const stableBorrowTotalAmount = BigInt(1e18);
      const stableInterestRate = BigInt(0.2e18);
      const stableAverageInterestRate = BigInt(0.1e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.interestRate = stableInterestRate;
      poolData.stableBorrowData.averageInterestRate = stableAverageInterestRate;
      await hubPool.setPoolData(poolData);

      // calculate new stable average interest rate
      const repaidBorrowAmount = BigInt(0.35e18);
      const violatorLoanStableRate = BigInt(0.2e18);
      const liquidatorOldBorrowAmount = BigInt(0);
      const liquidatorOldLoanStableRate = BigInt(0);
      const liquidatorNewLoanStableRate = BigInt(0.2e18);
      let newStableAverageInterestRate = calcAverageStableBorrowInterestRate(
        repaidBorrowAmount,
        BigInt(0),
        violatorLoanStableRate,
        violatorLoanStableRate,
        stableBorrowTotalAmount,
        stableAverageInterestRate
      );
      newStableAverageInterestRate = calcAverageStableBorrowInterestRate(
        liquidatorOldBorrowAmount,
        repaidBorrowAmount + liquidatorOldBorrowAmount,
        liquidatorOldLoanStableRate,
        liquidatorNewLoanStableRate,
        stableBorrowTotalAmount - repaidBorrowAmount,
        newStableAverageInterestRate
      );

      // update pool with liquidation
      const updatePoolWithLiquidation = await hubPool
        .connect(loanManager)
        .updatePoolWithLiquidation(
          repaidBorrowAmount,
          violatorLoanStableRate,
          liquidatorOldBorrowAmount,
          liquidatorOldLoanStableRate,
          liquidatorNewLoanStableRate
        );
      expect((await hubPool.getStableBorrowData())[10]).to.equal(newStableAverageInterestRate);
      await expect(updatePoolWithLiquidation).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should successfully update pool with liquidation when stable borrow and existing liquidator borrow", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data with interest data
      const depositTotalAmount = BigInt(10e18);
      const stableBorrowTotalAmount = BigInt(2e18);
      const stableInterestRate = BigInt(0.2e18);
      const stableAverageInterestRate = BigInt(0.1e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.interestRate = stableInterestRate;
      poolData.stableBorrowData.averageInterestRate = stableAverageInterestRate;
      await hubPool.setPoolData(poolData);

      // calculate new stable average interest rate
      const repaidBorrowAmount = BigInt(0.5e18);
      const violatorLoanStableRate = BigInt(0.15e18);
      const liquidatorOldBorrowAmount = BigInt(0.5e18);
      const liquidatorOldLoanStableRate = BigInt(0.05e18);
      const liquidatorNewLoanStableRate = BigInt(0.2e18);
      let newStableAverageInterestRate = calcAverageStableBorrowInterestRate(
        repaidBorrowAmount,
        BigInt(0),
        violatorLoanStableRate,
        violatorLoanStableRate,
        stableBorrowTotalAmount,
        stableAverageInterestRate
      );
      newStableAverageInterestRate = calcAverageStableBorrowInterestRate(
        liquidatorOldBorrowAmount,
        repaidBorrowAmount + liquidatorOldBorrowAmount,
        liquidatorOldLoanStableRate,
        liquidatorNewLoanStableRate,
        stableBorrowTotalAmount - repaidBorrowAmount,
        newStableAverageInterestRate
      );

      // update pool with liquidation
      const updatePoolWithLiquidation = await hubPool
        .connect(loanManager)
        .updatePoolWithLiquidation(
          repaidBorrowAmount,
          violatorLoanStableRate,
          liquidatorOldBorrowAmount,
          liquidatorOldLoanStableRate,
          liquidatorNewLoanStableRate
        );
      expect((await hubPool.getStableBorrowData())[10]).to.equal(newStableAverageInterestRate);
      await expect(updatePoolWithLiquidation).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should fail to update pool with liquidation when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // update pool with liquidation
      const repaidBorrowAmount = BigInt(1);
      const violatorLoanStableRate = BigInt(0);
      const liquidatorOldBorrowAmount = BigInt(1);
      const liquidatorOldLoanStableRate = BigInt(0);
      const liquidatorNewLoanStableRate = BigInt(0);
      const updatePoolWithLiquidation = hubPool
        .connect(user)
        .updatePoolWithLiquidation(
          repaidBorrowAmount,
          violatorLoanStableRate,
          liquidatorOldBorrowAmount,
          liquidatorOldLoanStableRate,
          liquidatorNewLoanStableRate
        );
      await expect(updatePoolWithLiquidation)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Prepare Pool For Switch Borrow Type", () => {
    it("Should successfully prepare pool for switch borrow type from stable to variable", async () => {
      const { admin, user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set pool data with interest data
      const lastUpdateTimestamp = BigInt(await getLatestBlockTimestamp());
      const borrowInterestRate = BigInt(0.048330237577e18);
      const borrowInterestIndex = BigInt(1.1394253233e18);
      const stableBorrowInterestRate = BigInt(0.14329e18);
      const poolData = getInitialPoolData();
      poolData.variableBorrowData.interestRate = borrowInterestRate;
      poolData.variableBorrowData.interestIndex = borrowInterestIndex;
      poolData.stableBorrowData.interestRate = stableBorrowInterestRate;
      poolData.lastUpdateTimestamp = lastUpdateTimestamp;
      await hubPool.setPoolData(poolData);

      // simulate interest over time period
      const timestamp = lastUpdateTimestamp + BigInt(getRandomInt(SECONDS_IN_DAY));
      await time.setNextBlockTimestamp(timestamp);
      const newVariableBorrowInterestIndex = calcBorrowInterestIndex(
        borrowInterestRate,
        borrowInterestIndex,
        timestamp - lastUpdateTimestamp,
        true
      );

      // prepare pool for switch borrow type
      const amount = BigInt(0.1e8);
      const maxStableRate = 0;
      const preparePoolForBorrow = await loanManager.preparePoolForSwitchBorrowType(amount, maxStableRate);
      await expect(preparePoolForBorrow).to.emit(hubPool, "InterestIndexesUpdated");
      await expect(preparePoolForBorrow)
        .to.emit(loanManager, "BorrowPoolParams")
        .withArgs([newVariableBorrowInterestIndex, stableBorrowInterestRate]);
    });

    it("Should successfully prepare pool for switch borrow type from variable to stable", async () => {
      const { admin, user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set pool data with interest data
      const lastUpdateTimestamp = BigInt(await getLatestBlockTimestamp());
      const depositTotalAmount = BigInt(100e18);
      const borrowInterestRate = BigInt(0.048330237577e18);
      const borrowInterestIndex = BigInt(1.1394253233e18);
      const stableBorrowInterestRate = BigInt(0.14329e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.variableBorrowData.interestRate = borrowInterestRate;
      poolData.variableBorrowData.interestIndex = borrowInterestIndex;
      poolData.stableBorrowData.interestRate = stableBorrowInterestRate;
      poolData.lastUpdateTimestamp = lastUpdateTimestamp;
      await hubPool.setPoolData(poolData);

      // simulate interest over time period
      const timestamp = lastUpdateTimestamp + BigInt(getRandomInt(SECONDS_IN_DAY));
      await time.setNextBlockTimestamp(timestamp);
      const newVariableBorrowInterestIndex = calcBorrowInterestIndex(
        borrowInterestRate,
        borrowInterestIndex,
        timestamp - lastUpdateTimestamp,
        true
      );

      // prepare pool for switch borrow type
      const amount = BigInt(0.1e8);
      const maxStableRate = stableBorrowInterestRate;
      const preparePoolForBorrow = await loanManager.preparePoolForSwitchBorrowType(amount, maxStableRate);
      await expect(preparePoolForBorrow).to.emit(hubPool, "InterestIndexesUpdated");
      await expect(preparePoolForBorrow)
        .to.emit(loanManager, "BorrowPoolParams")
        .withArgs([newVariableBorrowInterestIndex, stableBorrowInterestRate]);
    });

    it("Should fail to prepare pool for switch borrow type when pool is deprecated", async () => {
      const { admin, loanManager, hubPool, hubPoolLogicAddress } = await loadFixture(deployHubPoolFixture);

      // set pool to be deprecated
      const configData = {
        deprecated: true,
        stableBorrowSupported: true,
        canMintTsToken: true,
        flashLoanSupported: true,
      };
      await hubPool.connect(admin).updateConfigData(configData);

      // prepare pool for switch borrow type
      const amount = BigInt(1);
      const maxStableRate = 0;
      const preparePoolForSwitchBorrowType = hubPool
        .connect(loanManager)
        .preparePoolForSwitchBorrowType(amount, maxStableRate);
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(preparePoolForSwitchBorrowType).to.be.revertedWithCustomError(hubPoolLogic, "DeprecatedPool");
    });

    it("Should fail to prepare pool for switch borrow type when stable borrow not supported", async () => {
      const { admin, loanManager, hubPool, hubPoolLogicAddress } = await loadFixture(deployHubPoolFixture);

      // set pool to not support stable borrow
      const configData = {
        deprecated: false,
        stableBorrowSupported: false,
        canMintTsToken: true,
        flashLoanSupported: true,
      };
      await hubPool.connect(admin).updateConfigData(configData);

      // prepare pool for switch borrow type when variable to stable
      const amount = BigInt(1);
      const poolData = getInitialPoolData();
      let maxStableRate = poolData.stableBorrowData.interestRate;
      const preparePoolForSwitchBorrowType = hubPool
        .connect(loanManager)
        .preparePoolForSwitchBorrowType(amount, maxStableRate);
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(preparePoolForSwitchBorrowType).to.be.revertedWithCustomError(
        hubPoolLogic,
        "StableBorrowNotSupported"
      );

      // prepare pool for switch borrow type when stable to variable
      maxStableRate = BigInt(0);
      await hubPool.connect(loanManager).preparePoolForSwitchBorrowType(amount, maxStableRate);
    });

    it("Should fail to prepare pool for switch borrow type when stable borrow cap exceeded", async () => {
      const { loanManager, hubPool, hubPoolLogicAddress } = await loadFixture(deployHubPoolFixture);

      // set pool data with interest data
      const depositTotalAmount = BigInt(1e18);
      const stableBorrowPercentageCap = BigInt(0.1e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.capsData.stableBorrowPercentage = stableBorrowPercentageCap;
      await hubPool.setPoolData(poolData);

      // prepare pool for switch borrow type when stable borrow cap exceeded
      let amount = mulScale(depositTotalAmount, stableBorrowPercentageCap, ONE_18_DP) + BigInt(1);
      const maxStableRate = poolData.stableBorrowData.interestRate;
      const preparePoolForSwitchBorrowType = hubPool
        .connect(loanManager)
        .preparePoolForSwitchBorrowType(amount, maxStableRate);
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(preparePoolForSwitchBorrowType).to.be.revertedWithCustomError(
        hubPoolLogic,
        "StableBorrowPercentageCapExceeded"
      );

      // prepare pool for switch borrow type when stable borrow cap okay
      amount -= BigInt(1);
      await hubPool.connect(loanManager).preparePoolForSwitchBorrowType(amount, maxStableRate);
    });

    it("Should fail to prepare pool for switch borrow type when max stable rate exceeded", async () => {
      const { loanManager, hubPool, hubPoolLogicAddress } = await loadFixture(deployHubPoolFixture);

      // set pool data with deposit total amount
      const poolData = getInitialPoolData();
      const depositTotalAmount = BigInt(100e18);
      poolData.depositData.totalAmount = depositTotalAmount;
      await hubPool.setPoolData(poolData);

      // prepare pool for switch borrow type when max stable rate exceeded
      const amount = BigInt(1);
      let maxStableRate = poolData.stableBorrowData.interestRate - BigInt(1);
      const preparePoolForSwitchBorrowType = hubPool
        .connect(loanManager)
        .preparePoolForSwitchBorrowType(amount, maxStableRate);
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(preparePoolForSwitchBorrowType)
        .to.be.revertedWithCustomError(hubPoolLogic, "MaxStableRateExceeded")
        .withArgs(poolData.stableBorrowData.interestRate, maxStableRate);

      // prepare pool for switch borrow type when variable to stable and max stable rate okay
      maxStableRate = poolData.stableBorrowData.interestRate;
      await hubPool.connect(loanManager).preparePoolForSwitchBorrowType(amount, maxStableRate);
    });

    it("Should fail to prepare pool for switch borrow type when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // prepare pool for switch borrow
      const amount = BigInt(1);
      const maxStableRate = BigInt(0);
      const preparePoolForSwitchBorrowType = hubPool
        .connect(user)
        .preparePoolForSwitchBorrowType(amount, maxStableRate);
      await expect(preparePoolForSwitchBorrowType)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Update Pool With Switch Borrow Type", () => {
    it("Should successfully update pool with switch borrow type from stable to variable", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data
      const depositTotalAmount = BigInt(2e18);
      const variableBorrowTotalAmount = BigInt(1.43543539e18);
      const stableBorrowTotalAmount = BigInt(0.3254823e18);
      const stableInterestRate = BigInt(0.1420009e18);
      const stableAverageInterestRate = BigInt(0.19014e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.variableBorrowData.totalAmount = variableBorrowTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.interestRate = stableInterestRate;
      poolData.stableBorrowData.averageInterestRate = stableAverageInterestRate;
      await hubPool.setPoolData(poolData);

      // calculate new stable average interest rate
      const loanBorrowAmount = BigInt(0.1e18);
      const switchingToStable = false;
      const oldLoanBorrrowStableRate = BigInt(0.14732532e18);
      const newStableAverageInterestRate = calcAverageStableBorrowInterestRate(
        loanBorrowAmount,
        BigInt(0),
        oldLoanBorrrowStableRate,
        BigInt(0),
        stableBorrowTotalAmount,
        stableAverageInterestRate
      );

      // update pool with switch borrow type
      const updatePoolWithSwitchBorrowType = await hubPool
        .connect(loanManager)
        .updatePoolWithSwitchBorrowType(loanBorrowAmount, switchingToStable, oldLoanBorrrowStableRate);
      expect((await hubPool.getVariableBorrowData())[3]).to.equal(
        poolData.variableBorrowData.totalAmount + loanBorrowAmount
      );
      expect((await hubPool.getStableBorrowData())[8]).to.equal(
        poolData.stableBorrowData.totalAmount - loanBorrowAmount
      );
      expect((await hubPool.getStableBorrowData())[10]).to.equal(newStableAverageInterestRate);
      await expect(updatePoolWithSwitchBorrowType).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should handle div by zero when no stable remaining", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data
      const depositTotalAmount = BigInt(2e18);
      const variableBorrowTotalAmount = BigInt(1.43543539e18);
      const stableBorrowTotalAmount = BigInt(0.3254823e18);
      const stableInterestRate = BigInt(0.1420009e18);
      const stableAverageInterestRate = BigInt(0.19014e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.variableBorrowData.totalAmount = variableBorrowTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.interestRate = stableInterestRate;
      poolData.stableBorrowData.averageInterestRate = stableAverageInterestRate;
      await hubPool.setPoolData(poolData);

      // calculate new stable average interest rate
      const loanBorrowAmount = stableBorrowTotalAmount;
      const switchingToStable = false;
      const oldLoanBorrrowStableRate = stableAverageInterestRate;
      const newStableAverageInterestRate = BigInt(0);

      // update pool with switch borrow type
      const updatePoolWithSwitchBorrowType = await hubPool
        .connect(loanManager)
        .updatePoolWithSwitchBorrowType(loanBorrowAmount, switchingToStable, oldLoanBorrrowStableRate);
      expect((await hubPool.getVariableBorrowData())[3]).to.equal(
        poolData.variableBorrowData.totalAmount + loanBorrowAmount
      );
      expect((await hubPool.getStableBorrowData())[8]).to.equal(BigInt(0));
      expect((await hubPool.getStableBorrowData())[10]).to.equal(newStableAverageInterestRate);
      await expect(updatePoolWithSwitchBorrowType).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should successfully update pool with switch borrow type from variable to stable", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data
      const depositTotalAmount = BigInt(2e18);
      const variableBorrowTotalAmount = BigInt(1.43543539e18);
      const stableBorrowTotalAmount = BigInt(0.3254823e18);
      const stableInterestRate = BigInt(0.1420009e18);
      const stableAverageInterestRate = BigInt(0.19014e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.variableBorrowData.totalAmount = variableBorrowTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.interestRate = stableInterestRate;
      poolData.stableBorrowData.averageInterestRate = stableAverageInterestRate;
      await hubPool.setPoolData(poolData);

      // calculate new stable average interest rate
      const loanBorrowAmount = BigInt(0.1e18);
      const switchingToStable = true;
      const oldLoanBorrowStableRate = BigInt(0);
      const newStableAverageInterestRate = calcAverageStableBorrowInterestRate(
        BigInt(0),
        loanBorrowAmount,
        BigInt(0),
        stableInterestRate,
        stableBorrowTotalAmount,
        stableAverageInterestRate
      );

      // update pool with switch borrow type
      const updatePoolWithSwitchBorrowType = await hubPool
        .connect(loanManager)
        .updatePoolWithSwitchBorrowType(loanBorrowAmount, switchingToStable, oldLoanBorrowStableRate);
      expect((await hubPool.getVariableBorrowData())[3]).to.equal(
        poolData.variableBorrowData.totalAmount - loanBorrowAmount
      );
      expect((await hubPool.getStableBorrowData())[8]).to.equal(
        poolData.stableBorrowData.totalAmount + loanBorrowAmount
      );
      expect((await hubPool.getStableBorrowData())[10]).to.equal(newStableAverageInterestRate);
      await expect(updatePoolWithSwitchBorrowType).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should fail to update pool with switch borrow type when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // update pool with switch borrow type
      const loanBorrowAmount = BigInt(0.1e18);
      const switchingToStable = true;
      const oldLoanBorrowStableRate = BigInt(0);
      const updatePoolWithSwitchBorrowType = hubPool
        .connect(user)
        .updatePoolWithSwitchBorrowType(loanBorrowAmount, switchingToStable, oldLoanBorrowStableRate);
      await expect(updatePoolWithSwitchBorrowType)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Prepare Pool For Rebalance Up", () => {
    it("Should successfully prepare pool for rebalance up", async () => {
      const { admin, user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set pool data
      const lastUpdateTimestamp = BigInt(await getLatestBlockTimestamp());
      const depositTotalAmount = BigInt(10e18);
      const depositInterestRate = BigInt(0.013578335e18);
      const variableBorrowTotalAmount = BigInt(1.43543539e18);
      const borrowInterestRate = BigInt(0.048330237577e18);
      const borrowInterestIndex = BigInt(1.1394253233e18);
      const stableBorrowInterestRate = BigInt(0.14329e18);
      const stableBorrowTotalAmount = BigInt(0.3254823e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.depositData.interestRate = depositInterestRate;
      poolData.variableBorrowData.totalAmount = variableBorrowTotalAmount;
      poolData.variableBorrowData.interestRate = borrowInterestRate;
      poolData.variableBorrowData.interestIndex = borrowInterestIndex;
      poolData.stableBorrowData.interestRate = stableBorrowInterestRate;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.rebalanceUpUtilisationRatio = BigInt(0);
      poolData.stableBorrowData.rebalanceUpDepositInterestRate = BigInt(1e4);
      poolData.lastUpdateTimestamp = lastUpdateTimestamp;
      await hubPool.setPoolData(poolData);

      // simulate interest over time period
      const timestamp = lastUpdateTimestamp + BigInt(getRandomInt(SECONDS_IN_DAY));
      await time.setNextBlockTimestamp(timestamp);
      const newVariableBorrowInterestIndex = calcBorrowInterestIndex(
        borrowInterestRate,
        borrowInterestIndex,
        timestamp - lastUpdateTimestamp,
        true
      );

      // prepare pool for for rebalance up
      const preparePoolForRebalanceUp = await loanManager.preparePoolForRebalanceUp();
      await expect(preparePoolForRebalanceUp).to.emit(hubPool, "InterestIndexesUpdated");
      await expect(preparePoolForRebalanceUp)
        .to.emit(loanManager, "BorrowPoolParams")
        .withArgs([newVariableBorrowInterestIndex, stableBorrowInterestRate]);
    });

    it("Should fail to prepare pool for rebalance up when utilisation ratio is not reached", async () => {
      const { loanManager, hubPool, hubPoolLogicAddress } = await loadFixture(deployHubPoolFixture);

      // calculate utilisation ratio
      const depositTotalAmount = BigInt(10e18);
      const variableBorrowTotalAmount = BigInt(1.43543539e18);
      const stableBorrowTotalAmount = BigInt(0.3254823e18);
      const utilisationRatio = calcUtilisationRatio(
        variableBorrowTotalAmount + stableBorrowTotalAmount,
        depositTotalAmount
      );

      // set pool data
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.variableBorrowData.totalAmount = variableBorrowTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.rebalanceUpUtilisationRatio = utilisationRatio / ONE_14_DP + BigInt(1);
      poolData.stableBorrowData.rebalanceUpDepositInterestRate = BigInt(0);
      await hubPool.setPoolData(poolData);

      // prepare pool for for rebalance up when utilisation ratio too low
      const rebalanceUp = hubPool.connect(loanManager).preparePoolForRebalanceUp();
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(rebalanceUp).to.be.revertedWithCustomError(hubPoolLogic, "RebalanceUpUtilisationRatioNotReached");

      // prepare pool for for rebalance up when utilisation ratio okay
      poolData.stableBorrowData.rebalanceUpUtilisationRatio = utilisationRatio / ONE_14_DP;
      await hubPool.setPoolData(poolData);
      await hubPool.connect(loanManager).preparePoolForRebalanceUp();
    });

    it("Should fail to prepare pool for rebalance up when threshold exceeded", async () => {
      const { loanManager, hubPool, hubPoolLogicAddress } = await loadFixture(deployHubPoolFixture);

      // calculate rebalance up threshold
      const rebalanceUpDepositInterestRate = BigInt(0.1e4);
      const vr0 = BigInt(0);
      const vr1 = BigInt(0.02e6);
      const vr2 = BigInt(0.05e6);
      const rebalanceUpThreshold = calcRebalanceUpThreshold(rebalanceUpDepositInterestRate, vr0, vr1, vr2);

      // set pool data
      const poolData = getInitialPoolData();
      poolData.depositData.interestRate = rebalanceUpThreshold + BigInt(1);
      poolData.variableBorrowData.vr0 = vr0;
      poolData.variableBorrowData.vr1 = vr1;
      poolData.variableBorrowData.vr2 = vr2;
      poolData.stableBorrowData.rebalanceUpUtilisationRatio = BigInt(0);
      poolData.stableBorrowData.rebalanceUpDepositInterestRate = rebalanceUpDepositInterestRate;
      await hubPool.setPoolData(poolData);

      // prepare pool for for rebalance up when threshold exceeded
      const rebalanceUp = hubPool.connect(loanManager).preparePoolForRebalanceUp();
      const hubPoolLogic = await ethers.getContractAt("HubPoolLogic", hubPoolLogicAddress);
      await expect(rebalanceUp).to.be.revertedWithCustomError(hubPoolLogic, "RebalanceUpThresholdNotReached");

      // prepare pool for for rebalance up when threshold okay
      poolData.depositData.interestRate = rebalanceUpThreshold;
      await hubPool.setPoolData(poolData);
      await hubPool.connect(loanManager).preparePoolForRebalanceUp();
    });

    it("Should fail to prepare pool for rebalance up when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // prepare pool for for rebalance up
      const preparePoolForRebalanceUp = hubPool.connect(user).preparePoolForRebalanceUp();
      await expect(preparePoolForRebalanceUp)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Prepare Pool For Rebalance Down", () => {
    it("Should successfully prepare pool for rebalance down", async () => {
      const { admin, user, hubPool } = await loadFixture(deployHubPoolFixture);

      // deploy mock loan manager so can emit event with params
      const loanManager = await new HubPoolLogged__factory(user).deploy(hubPool);
      await hubPool.connect(admin).grantRole(LOAN_MANAGER_ROLE, loanManager);

      // set pool data
      const lastUpdateTimestamp = BigInt(await getLatestBlockTimestamp());
      const depositTotalAmount = BigInt(10e18);
      const depositInterestRate = BigInt(0.013578335e18);
      const variableBorrowTotalAmount = BigInt(1.43543539e18);
      const borrowInterestRate = BigInt(0.048330237577e18);
      const borrowInterestIndex = BigInt(1.1394253233e18);
      const stableBorrowInterestRate = BigInt(0.14329e18);
      const rebalanceDownDelta = BigInt(0.1e4);
      const stableBorrowTotalAmount = BigInt(0.3254823e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.depositData.interestRate = depositInterestRate;
      poolData.variableBorrowData.totalAmount = variableBorrowTotalAmount;
      poolData.variableBorrowData.interestRate = borrowInterestRate;
      poolData.variableBorrowData.interestIndex = borrowInterestIndex;
      poolData.stableBorrowData.interestRate = stableBorrowInterestRate;
      poolData.stableBorrowData.rebalanceDownDelta = rebalanceDownDelta;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.rebalanceUpUtilisationRatio = BigInt(0);
      poolData.stableBorrowData.rebalanceUpDepositInterestRate = BigInt(1e4);
      poolData.lastUpdateTimestamp = lastUpdateTimestamp;
      await hubPool.setPoolData(poolData);

      // simulate interest over time period
      const timestamp = lastUpdateTimestamp + BigInt(getRandomInt(SECONDS_IN_DAY));
      await time.setNextBlockTimestamp(timestamp);
      const newVariableBorrowInterestIndex = calcBorrowInterestIndex(
        borrowInterestRate,
        borrowInterestIndex,
        timestamp - lastUpdateTimestamp,
        true
      );
      const threshold = calcRebalanceDownThreshold(rebalanceDownDelta, stableBorrowInterestRate);

      // prepare pooll for rebalance down
      const preparePoolForRebalanceDown = await loanManager.preparePoolForRebalanceDown();
      await expect(preparePoolForRebalanceDown).to.emit(hubPool, "InterestIndexesUpdated");
      await expect(preparePoolForRebalanceDown)
        .to.emit(loanManager, "RebalanceDownPoolParams")
        .withArgs([newVariableBorrowInterestIndex, stableBorrowInterestRate, threshold]);
    });

    it("Should fail to prepare pool for rebalance down when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // prepare pool for for rebalance down
      const preparePoolForRebalanceDown = hubPool.connect(user).preparePoolForRebalanceDown();
      await expect(preparePoolForRebalanceDown)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Update Pool With Rebalance", () => {
    it("Should successfully update pool when rebalancing up", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data
      const depositTotalAmount = BigInt(0.5e18);
      const stableBorrowTotalAmount = BigInt(0.3254823e18);
      const stableInterestRate = BigInt(0.2420009e18);
      const stableAverageInterestRate = BigInt(0.19014e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.interestRate = stableInterestRate;
      poolData.stableBorrowData.averageInterestRate = stableAverageInterestRate;
      await hubPool.setPoolData(poolData);

      // calculate new stable average interest rate
      const loanBorrowAmount = BigInt(0.1e18);
      const oldLoanStableInterestRate = BigInt(0.2035411e18);
      const newStableAverageInterestRate = calcAverageStableBorrowInterestRate(
        loanBorrowAmount,
        loanBorrowAmount,
        oldLoanStableInterestRate,
        stableInterestRate,
        stableBorrowTotalAmount,
        stableAverageInterestRate
      );
      expect(newStableAverageInterestRate).to.be.greaterThan(stableAverageInterestRate);

      // update pool with rebalance
      const updatePoolWithRebalance = await hubPool
        .connect(loanManager)
        .updatePoolWithRebalance(loanBorrowAmount, oldLoanStableInterestRate);
      expect((await hubPool.getStableBorrowData())[8]).to.equal(poolData.stableBorrowData.totalAmount);
      expect((await hubPool.getStableBorrowData())[10]).to.equal(newStableAverageInterestRate);
      await expect(updatePoolWithRebalance).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should successfully update pool when rebalancing down", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // set pool data
      const depositTotalAmount = BigInt(0.5e18);
      const stableBorrowTotalAmount = BigInt(0.3254823e18);
      const stableInterestRate = BigInt(0.1420009e18);
      const stableAverageInterestRate = BigInt(0.19014e18);
      const poolData = getInitialPoolData();
      poolData.depositData.totalAmount = depositTotalAmount;
      poolData.stableBorrowData.totalAmount = stableBorrowTotalAmount;
      poolData.stableBorrowData.interestRate = stableInterestRate;
      poolData.stableBorrowData.averageInterestRate = stableAverageInterestRate;
      await hubPool.setPoolData(poolData);

      // calculate new stable average interest rate
      const loanBorrowAmount = BigInt(0.1e18);
      const oldLoanStableInterestRate = BigInt(0.2035411e18);
      const newStableAverageInterestRate = calcAverageStableBorrowInterestRate(
        loanBorrowAmount,
        loanBorrowAmount,
        oldLoanStableInterestRate,
        stableInterestRate,
        stableBorrowTotalAmount,
        stableAverageInterestRate
      );
      expect(newStableAverageInterestRate).to.be.lessThan(stableAverageInterestRate);

      // update pool with rebalance
      const updatePoolWithRebalance = await hubPool
        .connect(loanManager)
        .updatePoolWithRebalance(loanBorrowAmount, oldLoanStableInterestRate);
      expect((await hubPool.getStableBorrowData())[8]).to.equal(poolData.stableBorrowData.totalAmount);
      expect((await hubPool.getStableBorrowData())[10]).to.equal(newStableAverageInterestRate);
      await expect(updatePoolWithRebalance).to.emit(hubPool, "InterestRatesUpdated");
      await verifyInterestRates(hubPool);
    });

    it("Should fail to update pool with rebalance when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // update pool with rebalance down
      const loanBorrowAmount = BigInt(0.1e18);
      const oldLoanStableInterestRate = BigInt(1.0935411e18);
      const updatePoolWithRebalance = hubPool
        .connect(user)
        .updatePoolWithRebalance(loanBorrowAmount, oldLoanStableInterestRate);
      await expect(updatePoolWithRebalance)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Mint TS Token For Fee Recipient", () => {
    it("Should successfully mint ts token for fee recipient", async () => {
      const { loanManager, hubPool, initialPoolData: poolData } = await loadFixture(deployHubPoolFixture);

      const { tsTokenFeeRecipient } = poolData.feeData;

      // mint ts token for fee recipient
      const amount = BigInt(0.005e18);
      const mintTsTokenForFeeRecipient = await hubPool.connect(loanManager).mintTsTokenForFeeRecipient(amount);
      await expect(mintTsTokenForFeeRecipient)
        .to.emit(hubPool, "Transfer")
        .withArgs(ethers.ZeroAddress, tsTokenFeeRecipient, amount);
    });

    it("Should fail to mint ts token for fee recipient when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // mint ts token for fee recipient
      const amount = BigInt(1);
      const mintTsTokenForFeeRecipient = hubPool.connect(user).mintTsTokenForFeeRecipient(amount);
      await expect(mintTsTokenForFeeRecipient)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Mint TS Token", () => {
    it("Should successfully mint ts token", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // mint ts token
      const recipient = getRandomAddress();
      const amount = BigInt(0.005e18);
      const mintTsToken = await hubPool.connect(loanManager).mintTsToken(recipient, amount);
      await expect(mintTsToken).to.emit(hubPool, "Transfer").withArgs(ethers.ZeroAddress, recipient, amount);
    });

    it("Should fail to mint ts token when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // mint ts token
      const recipient = getRandomAddress();
      const amount = BigInt(1);
      const mintTsToken = hubPool.connect(user).mintTsToken(recipient, amount);
      await expect(mintTsToken)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Burn TS Token For Fee Recipient", () => {
    it("Should successfully burn ts token for fee recipient", async () => {
      const { loanManager, hubPool } = await loadFixture(deployHubPoolFixture);

      // mint ts token so have balance
      const recipient = getRandomAddress();
      const mintAmount = BigInt(0.005e18);
      await hubPool.connect(loanManager).mintTsToken(recipient, mintAmount);

      // burn ts token
      const sender = recipient;
      const burnAmount = mintAmount / BigInt(2);
      const burnTsToken = hubPool.connect(loanManager).burnTsToken(sender, burnAmount);
      await expect(burnTsToken).to.emit(hubPool, "Transfer").withArgs(sender, ethers.ZeroAddress, burnAmount);
    });

    it("Should fail to burn ts token for fee recipient when sender is not loan manager", async () => {
      const { user, hubPool } = await loadFixture(deployHubPoolFixture);

      // mint ts token
      const sender = getRandomAddress();
      const amount = BigInt(1);
      const burnTsToken = hubPool.connect(user).burnTsToken(sender, amount);
      await expect(burnTsToken)
        .to.be.revertedWithCustomError(hubPool, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, LOAN_MANAGER_ROLE);
    });
  });

  describe("Flash Loan", () => {
    it("Should successfully get max flash loan", async () => {
      const { admin, loanManager, hubPool, hubPoolAddress } = await loadFixture(deployHubPoolFixture);

      // 0 when unknown token
      let maxFlashLoan = await hubPool.maxFlashLoan(getRandomAddress());
      expect(maxFlashLoan).to.equal(0);

      // max uint256 when total supply is zero
      maxFlashLoan = await hubPool.maxFlashLoan(hubPoolAddress);
      expect(maxFlashLoan).to.equal(ethers.MaxUint256);

      // max uint256 - total supply
      const recipient = getRandomAddress();
      const totalSupply = BigInt(14.383257235e18);
      await hubPool.connect(loanManager).mintTsToken(recipient, totalSupply);
      maxFlashLoan = await hubPool.maxFlashLoan(hubPoolAddress);
      expect(maxFlashLoan).to.equal(ethers.MaxUint256 - totalSupply);

      // 0 when flash loan not supported
      const poolData = getInitialPoolData();
      poolData.configData.flashLoanSupported = false;
      await hubPool.setPoolData(poolData);
      maxFlashLoan = await hubPool.maxFlashLoan(hubPoolAddress);
      expect(maxFlashLoan).to.equal(0);
    });

    it("Should successfully calculate flash fee", async () => {
      const { hubPool, hubPoolAddress, initialPoolData: poolData } = await loadFixture(deployHubPoolFixture);

      // calculate flash fee
      const amount = BigInt(2.15e18);
      const expectedFlashFee = calcFlashLoanFeeAmount(amount, poolData.feeData.flashLoanFee);

      // flash fee
      const flashFee = await hubPool.flashFee(hubPoolAddress, amount);
      expect(flashFee).to.equal(expectedFlashFee);
    });

    it("Should fail to calculate flash fee when unknown token", async () => {
      const { hubPool } = await loadFixture(deployHubPoolFixture);

      // flash fee
      const token = getRandomAddress();
      const amount = BigInt(1);
      const flashFee = hubPool.flashFee(token, amount);
      await expect(flashFee).to.be.revertedWithCustomError(hubPool, "ERC3156UnsupportedToken").withArgs(token);
    });

    it("Should successfully set flash fee receiver", async () => {
      const { hubPool, initialPoolData: poolData } = await loadFixture(deployHubPoolFixture);

      // check flash fee receiver
      let flashFeeReceiver = await hubPool.flashFeeReceiver();
      expect(flashFeeReceiver).to.equal(poolData.feeData.tsTokenFeeRecipient);
    });

    it("Should successfully take flash loan", async () => {});
  });
});
