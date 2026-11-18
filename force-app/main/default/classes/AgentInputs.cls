/**
 * Helpers shared by the agent actions (Agent* classes).
 *
 * The agent passes ids as text: it may send a name, a typo or several ids. Each action checks its
 * input here and answers with a message the agent can show, instead of failing.
 */
public with sharing class AgentInputs {
  public class InputException extends Exception {
  }

  /** One record id of the given object, or an InputException naming what was expected. */
  public static Id toId(String value, SObjectType type, String label) {
    Id result = parse(value);
    if (result == null || result.getSObjectType() != type) {
      String received = '';
      if (value != null) {
        received = value.left(40);
      }
      throw new InputException(
        'I need the ' +
          label +
          ' record id (got "' +
          received +
          '"). Find it first with the search action.'
      );
    }
    return result;
  }

  /** Optional id: null when empty. */
  public static Id toOptionalId(String value, SObjectType type, String label) {
    if (String.isBlank(value)) {
      return null;
    }
    return toId(value, type, label);
  }

  /** Ids separated by commas, spaces or new lines. Empty input gives an empty list. */
  public static List<Id> toIds(String value, SObjectType type, String label) {
    List<Id> result = new List<Id>();
    if (String.isBlank(value)) {
      return result;
    }
    for (String part : value.split('[,;\\s]+')) {
      if (String.isNotBlank(part)) {
        Id item = toId(part, type, label);
        if (!result.contains(item)) {
          result.add(item);
        }
      }
    }
    return result;
  }

  /** Message for an unexpected error: logged in full, short for the recruiter. */
  public static String failure(String action, Exception ex) {
    if (ex instanceof InputException) {
      return ex.getMessage();
    }
    Logger.error('Agent action "' + action + '" failed')
      .setExceptionDetails(ex)
      .addTag(Constants.LOG_TAG_AGENT_DECISION);
    Logger.saveLog();
    return 'Sorry, "' + action + '" failed: ' + ex.getMessage();
  }

  private static Id parse(String value) {
    if (String.isBlank(value)) {
      return null;
    }
    try {
      return Id.valueOf(value.trim());
    } catch (Exception ex) {
      return null;
    }
  }
}
