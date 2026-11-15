/** Shared helpers for the careers portal components. */

const DATE_FORMAT = new Intl.DateTimeFormat("en-US", {
  year: "numeric",
  month: "short",
  day: "numeric",
  timeZone: "UTC"
});

/** Tag shown on a job: its experience level. */
export function experienceTag(minYears) {
  if (minYears === null || minYears === undefined || minYears === 0) {
    return "All levels";
  }
  return `${minYears}+ years`;
}

/** "2026-12-15" -> "Apply by Dec 15, 2026". */
export function dueDateLabel(dueDate) {
  return dueDate
    ? `Apply by ${DATE_FORMAT.format(new Date(`${dueDate}T00:00:00Z`))}`
    : "Open until filled";
}

export function errorMessage(error) {
  if (!error) {
    return "Something went wrong. Please try again later.";
  }
  if (Array.isArray(error.body)) {
    return error.body.map((item) => item.message).join(", ");
  }
  return (
    error.body?.message ||
    error.message ||
    "Something went wrong. Please try again later."
  );
}

/** Reads a File as base64 (without the "data:...;base64," prefix). */
export function readAsBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(",")[1] || "");
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

export function extensionOf(fileName) {
  const dot = fileName.lastIndexOf(".");
  return dot === -1 ? "" : fileName.slice(dot + 1).toLowerCase();
}
