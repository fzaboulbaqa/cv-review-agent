/**
 * Shared display helpers for the candidate components.
 * Score levels are display-only: the score itself comes from ScoringService.
 */
const SCORE_LEVELS = [
  {
    min: 75,
    key: "strong",
    label: "Strong match",
    badgeClass: "slds-theme_success"
  },
  {
    min: 50,
    key: "partial",
    label: "Partial match",
    badgeClass: "slds-theme_warning"
  },
  { min: 0, key: "weak", label: "Weak match", badgeClass: "slds-theme_error" }
];

const NOT_SCORED = {
  key: "none",
  label: "Not scored",
  badgeClass: "slds-badge_lightest"
};

export const NOT_FOUND_TEXT = "Not found in CV";

export function scoreLevel(score) {
  if (score === null || score === undefined) {
    return NOT_SCORED;
  }
  // Levels are sorted from the highest minimum: the first one reached wins.
  for (const level of SCORE_LEVELS) {
    if (score >= level.min) {
      return level;
    }
  }
  return NOT_SCORED;
}

/** "Sara Haddad" -> "SH", "Omar" -> "O". */
export function initials(name) {
  if (!name) {
    return "?";
  }
  const words = name.trim().split(/\s+/);
  const first = words[0].charAt(0);
  let last = "";
  if (words.length > 1) {
    const lastWord = words[words.length - 1];
    last = lastWord.charAt(0);
  }
  return (first + last).toUpperCase();
}

/** Joins the non-empty parts with a dot: "Developer · Morocco". */
export function subtitle(...parts) {
  const filled = parts.filter(
    (part) => part !== null && part !== undefined && part !== ""
  );
  return filled.join(" · ");
}

export function errorMessage(error) {
  if (!error) {
    return "Unknown error";
  }
  // Some errors carry a list of messages in their body.
  if (Array.isArray(error.body)) {
    const messages = error.body.map((item) => item.message);
    return messages.join(", ");
  }
  if (error.body && error.body.message) {
    return error.body.message;
  }
  if (error.message) {
    return error.message;
  }
  return "Unknown error";
}
