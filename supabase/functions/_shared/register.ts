/**
 * Validation of the "registered" value supplied with a KYC request.
 *
 * The value is either an email address or a Madagascar mobile number. A number
 * is accepted only when it is exactly ten digits and starts with one of the
 * operator prefixes 032/033/034/037/038. This mirrors the client-side rule in
 * `mobile/lib/core/validators.dart`; the server stays the authority.
 */

const REGISTER_PHONE_PATTERN = /^(032|033|034|037|038)[0-9]{7}$/;

/** True for an email, or a ten-digit Madagascar number with a valid prefix. */
export function isValidRegisterNumber(registerValue: string): boolean {
  if (registerValue.includes("@")) return true;
  const digits = registerValue.replace(/[^0-9]/g, "");
  return REGISTER_PHONE_PATTERN.test(digits);
}
