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
  if (!dueDate) {
    return "Open until filled";
  }
  // The date has no time: read it as midnight UTC so the day never shifts.
  const date = new Date(`${dueDate}T00:00:00Z`);
  return `Apply by ${DATE_FORMAT.format(date)}`;
}

const GENERIC_ERROR = "Something went wrong. Please try again later.";

export function errorMessage(error) {
  if (!error) {
    return GENERIC_ERROR;
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
  return GENERIC_ERROR;
}

/** Reads a File as base64 (without the "data:...;base64," prefix). */
export function readAsBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      // reader.result looks like "data:application/pdf;base64,JVBERi0..."
      const dataUrl = String(reader.result);
      const base64 = dataUrl.split(",")[1];
      resolve(base64 || "");
    };
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

/** "My CV.PDF" -> "pdf". No dot -> "". */
export function extensionOf(fileName) {
  const dot = fileName.lastIndexOf(".");
  if (dot === -1) {
    return "";
  }
  return fileName.slice(dot + 1).toLowerCase();
}
