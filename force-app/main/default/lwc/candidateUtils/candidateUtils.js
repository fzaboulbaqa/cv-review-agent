/**
 * Shared display helpers for the candidate components.
 * Score levels are display-only: the score itself comes from ScoringService.
 */
const SCORE_LEVELS = [
  { min: 75, label: "Strong match", badgeClass: "slds-theme_success" },
  { min: 50, label: "Partial match", badgeClass: "slds-theme_warning" },
  { min: 0, label: "Weak match", badgeClass: "slds-theme_error" }
];

const NOT_SCORED = { label: "Not scored", badgeClass: "slds-badge_lightest" };

export const NOT_FOUND_TEXT = "Not found in CV";

export function scoreLevel(score) {
  if (score === null || score === undefined) {
    return NOT_SCORED;
  }
  return SCORE_LEVELS.find((level) => score >= level.min) || NOT_SCORED;
}

/** "Sara Haddad" -> "SH", "Omar" -> "O". */
export function initials(name) {
  if (!name) {
    return "?";
  }
  const words = name.trim().split(/\s+/);
  const first = words[0].charAt(0);
  const last = words.length > 1 ? words[words.length - 1].charAt(0) : "";
  return (first + last).toUpperCase();
}

export function subtitle(...parts) {
  return parts
    .filter((part) => part !== null && part !== undefined && part !== "")
    .join(" · ");
}

export function errorMessage(error) {
  if (!error) {
    return "Unknown error";
  }
  if (Array.isArray(error.body)) {
    return error.body.map((item) => item.message).join(", ");
  }
  return error.body?.message || error.message || "Unknown error";
}
