// =====================================================================
//  FAKE CREDENTIAL — PLANTED ON PURPOSE FOR THE SECRET-SCANNING DEMO.
//
//  This is NOT a real key. It was never issued by any provider, it is
//  not linked to any account, and it cannot be used for anything. It is
//  shaped like an AWS access key ID only so that gitleaks' default
//  `aws-access-token` rule fires and the `secret-scan` CI job fails on
//  this branch (demo/leaked-secret). Never do this in a real project:
//  read credentials from the environment or a secrets manager instead.
// =====================================================================

module.exports = {
  // Wrong: a credential hard-coded in source. The demo branch exists to
  // show the pipeline blocking exactly this.
  paymentsApiKey: 'AKIAFAKELSCSDEMOKEYX',

  // Right: read it from the environment at run time.
  // paymentsApiKey: process.env.PAYMENTS_API_KEY,
};
