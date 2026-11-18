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
    // No search text: every job.
    String pattern = '%';
    if (String.isNotBlank(searchText)) {
      pattern = '%' + searchText.trim() + '%';
    }
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
      lines.add(describe(job));
    }
    if (lines.isEmpty()) {
      return 'No job found for "' + searchText + '".';
    }
    return String.join(lines, '\n');
  }

  /** "Name | location | 3 applicant(s) | due date | jobId: ..." */
  private static String describe(Job__c job) {
    String location = 'no location';
    if (job.Location__c != null) {
      location = job.Location__c;
    }
    String dueDate = 'no due date';
    if (job.Due_Date__c != null) {
      dueDate = 'due ' + job.Due_Date__c.format();
    }
    Integer applicantCount = job.Job_Applicants__r.size();

    String line = job.Name + ' | ' + location;
    line += ' | ' + applicantCount + ' applicant(s)';
    line += ' | ' + dueDate;
    line += ' | jobId: ' + job.Id;
    return line;
  }
}
