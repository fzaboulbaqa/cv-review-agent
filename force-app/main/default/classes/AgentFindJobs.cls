/** Agent action: finds jobs by title or location, so the agent gets the job id to work with. */
public with sharing class AgentFindJobs {
  private static final Integer MAX_RESULTS = 20;

  public class Request {
    @InvocableVariable(
      label='Search Text'
      description='Part of the job title or location, e.g. "Salesforce Developer". Leave empty to list the open jobs.'
    )
    public String searchText;
  }

  public class Result {
    @InvocableVariable(
      label='Jobs'
      description='One line per job: title, location, applicants, due date and job id.'
    )
    public String message;
  }

  @InvocableMethod(
    label='Find Jobs'
    description='Finds jobs by title or location and returns their ids. Use it before any action that needs a job id.'
    category='CV Review Agent'
  )
  public static List<Result> find(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request request : requests) {
      Result result = new Result();
      try {
        result.message = find(request.searchText);
      } catch (Exception ex) {
        result.message = AgentInputs.failure('Find Jobs', ex);
      }
      results.add(result);
    }
    return results;
  }

  private static String find(String searchText) {
    String pattern = String.isBlank(searchText)
      ? '%'
      : '%' + searchText.trim() + '%';
    List<String> lines = new List<String>();
    for (Job__c job : [
      SELECT
        Id,
        Name,
        Location__c,
        Due_Date__c,
        (SELECT Id FROM Job_Applicants__r)
      FROM Job__c
      WHERE Name LIKE :pattern OR Location__c LIKE :pattern
      WITH USER_MODE
      ORDER BY Name
      LIMIT :MAX_RESULTS
    ]) {
      lines.add(
        job.Name +
          ' | ' +
          (job.Location__c == null ? 'no location' : job.Location__c) +
          ' | ' +
          job.Job_Applicants__r.size() +
          ' applicant(s)' +
          ' | ' +
          (job.Due_Date__c == null
            ? 'no due date'
            : 'due ' + job.Due_Date__c.format()) +
          ' | jobId: ' +
          job.Id
      );
    }
    return lines.isEmpty()
      ? 'No job found for "' + searchText + '".'
      : String.join(lines, '\n');
  }
}
