/**
 * Test double for AiPrompt: returns a fixed answer per prompt template and records the calls.
 * Einstein can't run in Apex tests.
 */
@IsTest
public class AiPromptFake implements AiPrompt.Runner {
  public Map<String, String> answers = new Map<String, String>();
  /** Templates that throw, to test the error paths. */
  public Set<String> failing = new Set<String>();
  public List<String> calls = new List<String>();
  public List<Map<String, Object>> inputs = new List<Map<String, Object>>();

  public static AiPromptFake install() {
    AiPromptFake fake = new AiPromptFake();
    AiPrompt.runner = fake;
    return fake;
  }

  public AiPromptFake answer(String templateName, String text) {
    answers.put(templateName, text);
    return this;
  }

  public String run(String templateName, Map<String, Object> inputValues) {
    calls.add(templateName);
    inputs.add(inputValues);
    if (failing.contains(templateName)) {
      throw new AiPrompt.AiException('Einstein is not available');
    }
    return answers.get(templateName);
  }

  public Integer count(String templateName) {
    Integer total = 0;
    for (String call : calls) {
      if (call == templateName) {
        total++;
      }
    }
    return total;
  }
}
