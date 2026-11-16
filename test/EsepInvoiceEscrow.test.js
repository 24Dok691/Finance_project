import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

describe("EsepInvoiceEscrow", function () {
  let escrow, admin, treasury, sme, buyer, otherBuyer, investor;
  const invoiceHash = ethers.keccak256(ethers.toUtf8Bytes("INV-2026-001-SYNTHETIC"));
  const faceValue = ethers.parseEther("10.0"); // Simulated 10 units (= KZT 1,000,000)
  const discountedOffer = ethers.parseEther("9.5"); // 5% factoring discount

  beforeEach(async function () {
    [admin, treasury, sme, buyer, otherBuyer, investor] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("EsepInvoiceEscrow");
    escrow = await Factory.deploy(treasury.address);

    await escrow.grantRole(await escrow.SME_ROLE(), sme.address);
    await escrow.grantRole(await escrow.BUYER_ROLE(), buyer.address);
    await escrow.grantRole(await escrow.BUYER_ROLE(), otherBuyer.address);
    await escrow.grantRole(await escrow.INVESTOR_ROLE(), investor.address);
  });

  it("1. Completes full lifecycle: register -> verify -> fund -> settle with accurate fee split", async function () {
    const dueDate = Math.floor(Date.now() / 1000) + 86400 * 60;

    await escrow.connect(sme).registerInvoice(invoiceHash, buyer.address, faceValue, dueDate);
    await escrow.connect(buyer).verifyInvoice(invoiceHash);

    const expectedFee = ethers.parseEther("0.15");
    const expectedNetSme = ethers.parseEther("9.35");

    await expect(
      escrow.connect(investor).fundInvoice(invoiceHash, { value: discountedOffer })
    ).to.changeEtherBalances(ethers, [treasury, sme], [expectedFee, expectedNetSme]);

    await expect(
      escrow.connect(buyer).settleInvoice(invoiceHash, { value: faceValue })
    ).to.changeEtherBalance(ethers, investor, faceValue);

    const inv = await escrow.invoices(invoiceHash);
    expect(inv.status).to.equal(3n); // Settled
  });

  it("2. Prevents double-pledging by rejecting duplicate invoice hashes", async function () {
    const dueDate = Math.floor(Date.now() / 1000) + 86400 * 30;
    await escrow.connect(sme).registerInvoice(invoiceHash, buyer.address, faceValue, dueDate);

    await expect(
      escrow.connect(sme).registerInvoice(invoiceHash, buyer.address, faceValue, dueDate)
    ).to.be.revertedWith("Duplicate invoice: already registered");
  });

  it("3. Blocks unauthorized buyer from verifying another buyer's invoice", async function () {
    const dueDate = Math.floor(Date.now() / 1000) + 86400 * 30;
    await escrow.connect(sme).registerInvoice(invoiceHash, buyer.address, faceValue, dueDate);

    await expect(
      escrow.connect(otherBuyer).verifyInvoice(invoiceHash)
    ).to.be.revertedWith("Only designated buyer can verify");
  });

  it("4. Prevents investor from funding an unverified invoice", async function () {
    const dueDate = Math.floor(Date.now() / 1000) + 86400 * 30;
    await escrow.connect(sme).registerInvoice(invoiceHash, buyer.address, faceValue, dueDate);

    await expect(
      escrow.connect(investor).fundInvoice(invoiceHash, { value: discountedOffer })
    ).to.be.revertedWith("Invoice must be verified first");
  });

  it("5. Enforces exact face value repayment upon buyer settlement", async function () {
    const dueDate = Math.floor(Date.now() / 1000) + 86400 * 30;
    await escrow.connect(sme).registerInvoice(invoiceHash, buyer.address, faceValue, dueDate);
    await escrow.connect(buyer).verifyInvoice(invoiceHash);
    await escrow.connect(investor).fundInvoice(invoiceHash, { value: discountedOffer });

    await expect(
      escrow.connect(buyer).settleInvoice(invoiceHash, { value: ethers.parseEther("9.0") })
    ).to.be.revertedWith("Must pay exact face value");
  });

  it("6. Allows admin to pause contract in an emergency and blocks registrations", async function () {
    const dueDate = Math.floor(Date.now() / 1000) + 86400 * 30;
    await escrow.connect(admin).pause();

    await expect(
      escrow.connect(sme).registerInvoice(invoiceHash, buyer.address, faceValue, dueDate)
    ).to.be.revertedWithCustomError(escrow, "EnforcedPause");
  });
});