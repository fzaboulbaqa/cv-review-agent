/**
 * The only place that calls the AI: runs a Prompt Builder template (Einstein, models configured
 * in the template) and returns the text it generated.
 *
 * Tests replace the runner with a fake (AiPrompt.runner), since Einstein can't run in Apex tests.
 *
 * Inputs are passed by their API name in the template, without the "Input:" prefix.
 * A file input (ContentDocument) is passed with fileInput(contentDocumentId).
 *
 * Callouts: Einstein counts as a callout, so no DML may run before it in the same transaction.
 * The services call the AI first and save afterwards.
 */
public with sharing class AiPrompt {
  public interface Runner {
    String run(String templateName, Map<String, Object> inputs);
  }

  public class AiException extends Exception {
  }

  @TestVisible
  private static Runner runner = new EinsteinRunner();

  public static String run(String templateName, Map<String, Object> inputs) {
    String text = runner.run(templateName, inputs);
    if (String.isBlank(text)) {
      throw new AiException(
        'The AI returned an empty answer (template ' + templateName + ').'
      );
    }
    return withoutCourtesy(text);
  }

  /**
   * Removes "Thank you ..." lines at the start or end of an answer: the models add them despite
   * the instructions, and they read badly in a recruiter's tool.
   */
  public static String withoutCourtesy(String text) {
    List<String> lines = text.trim().split('\n');
    while (!lines.isEmpty() && isCourtesy(lines[0])) {
      lines.remove(0);
    }
    while (!lines.isEmpty() && isCourtesy(lines[lines.size() - 1])) {
      lines.remove(lines.size() - 1);
    }
    // Also a closing "Thank you ..." sentence at the end of the last line.
    return String.join(lines, '\n')
      .replaceAll('(?i)\\s*(thank you|thanks for)[^.!\\n]*[.!]?\\s*$', '')
      .trim();
  }

  private static Boolean isCourtesy(String line) {
    String value = line.trim().toLowerCase();
    return value == '' ||
      value.startsWith('thank you') ||
      value.startsWith('thanks for');
  }

  /** Value for a File (ContentDocument) input of a flex template. */
  public static Object fileInput(Id contentDocumentId) {
    return new Map<String, Object>{ 'id' => contentDocumentId };
  }

  /**
   * Reads the JSON object in an AI answer. Models sometimes wrap it in ```json fences or add a
   * sentence around it: everything outside the outer braces is ignored.
   */
  public static Map<String, Object> parseJsonObject(String text) {
    Integer start = text == null ? -1 : text.indexOf('{');
    Integer finish = text == null ? -1 : text.lastIndexOf('}');
    if (start < 0 || finish <= start) {
      throw new AiException('The AI answer is not JSON.');
    }
    try {
      return (Map<String, Object>) JSON.deserializeUntyped(
        text.substring(start, finish + 1)
      );
    } catch (Exception ex) {
      throw new AiException(
        'The AI answer is not valid JSON: ' + ex.getMessage()
      );
    }
  }

  // ---------- Safe readers for untyped JSON (the AI may return any type) ----------

  public static String text(Map<String, Object> data, String key) {
    Object value = data == null ? null : data.get(key);
    if (value == null) {
      return null;
    }
    String result = String.valueOf(value).trim();
    // Models sometimes write "null" or "N/A" instead of leaving the value out.
    Set<String> empty = new Set<String>{ '', 'null', 'n/a', 'none', 'unknown' };
    return empty.contains(result.toLowerCase()) ? null : result;
  }

  public static Decimal num(Map<String, Object> data, String key) {
    Object value = data == null ? null : data.get(key);
    if (value instanceof Decimal) {
      return (Decimal) value;
    }
    if (value instanceof Integer) {
      return (Integer) value;
    }
    if (value instanceof Long) {
      return (Long) value;
    }
    if (value instanceof Double) {
      return Decimal.valueOf((Double) value);
    }
    try {
      return value == null
        ? null
        : Decimal.valueOf(String.valueOf(value).trim());
    } catch (TypeException ex) {
      return null;
    }
  }

  public static Boolean bool(Map<String, Object> data, String key) {
    Object value = data == null ? null : data.get(key);
    return value == true || String.valueOf(value)?.toLowerCase() == 'true';
  }

  public static List<Map<String, Object>> objects(
    Map<String, Object> data,
    String key
  ) {
    List<Map<String, Object>> result = new List<Map<String, Object>>();
    Object value = data == null ? null : data.get(key);
    if (value instanceof List<Object>) {
      for (Object item : (List<Object>) value) {
        if (item instanceof Map<String, Object>) {
          result.add((Map<String, Object>) item);
        }
      }
    }
    return result;
  }

  /** Einstein implementation (Prompt Builder through Connect API). */
  private class EinsteinRunner implements Runner {
    public String run(String templateName, Map<String, Object> inputs) {
      ConnectApi.EinsteinPromptTemplateGenerationsInput request = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
      request.isPreview = false;
      request.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
      request.inputParams = new Map<String, ConnectApi.WrappedValue>();
      for (String name : inputs.keySet()) {
        ConnectApi.WrappedValue value = new ConnectApi.WrappedValue();
        value.value = inputs.get(name);
        request.inputParams.put('Input:' + name, value);
      }
      ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
        templateName,
        request
      );
      if (response.generations == null || response.generations.isEmpty()) {
        return null;
      }
      return response.generations[0].text;
    }
  }
}
