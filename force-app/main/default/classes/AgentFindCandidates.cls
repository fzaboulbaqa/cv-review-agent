/**
 * Agent action: finds candidates by name, title or skill, or lists the applicants of a job, so
 * the agent gets the ids it needs for the other actions.
 */
public with sharing class AgentFindCandidates {
  private static final Integer MAX_RESULTS = 25;

  public class Request {
    @InvocableVariable(
      label='Search Text'
      description='Part of a candidate name, a job title or a skill, e.g. "Sara" or "Apex". Optional when a job id is given.'
    )
    public String searchText;

    @InvocableVariable(
      label='Job ID'
      description='Optional. Lists the applicants of this job (with their application id and score).'
    )
    public String jobId;
  }

  public class Result {
    @InvocableVariable(
      label='Candidates'
      description='One line per candidate with the candidateId (and applicantId and score for a job).'
    )
    public String message;
  }

  @InvocableMethod(
    label='Find Candidates'
    description='Finds candidates by name, title or skill, or lists the applicants of a job. Returns their ids.'
    category='CV Review Agent'
  )
  public static List<Result> find(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request request : requests) {
      Result result = new Result();
      try {
        Id jobId = AgentInputs.toOptionalId(
          request.jobId,
          Job__c.SObjectType,
          'job'
        );
        result.message = jobId == null
          ? search(request.searchText)
          : applicants(jobId, request.searchText);
      } catch (Exception ex) {
        result.message = AgentInputs.failure('Find Candidates', ex);
      }
      results.add(result);
    }
    return results;
  }

  private static String search(String searchText) {
    if (String.isBlank(searchText)) {
      throw new AgentInputs.InputException(
        'Tell me a name, title or skill to search for, or a job.'
      );
    }
    String pattern = '%' + searchText.trim() + '%';
    Set<Id> bySkill = new Set<Id>();
    for (Candidate_Skill__c link : [
      SELECT Candidate__c
      FROM Candidate_Skill__c
      WHERE Skill__r.Name LIKE :pattern
      WITH USER_MODE
      LIMIT 500
    ]) {
      bySkill.add(link.Candidate__c);
    }
    List<String> lines = new List<String>();
    for (Candidate__c candidate : [
      SELECT Id, Name, Current_Title__c, Years_Experience__c, Country__c
      FROM Candidate__c
      WHERE
        Name LIKE :pattern
        OR Current_Title__c LIKE :pattern
        OR Id IN :bySkill
      WITH USER_MODE
      ORDER BY Name
      LIMIT :MAX_RESULTS
    ]) {
      lines.add(describe(candidate) + ' | candidateId: ' + candidate.Id);
    }
    return lines.isEmpty()
      ? 'No candidate found for "' + searchText + '".'
      : String.join(lines, '\n');
  }

  private static String applicants(Id jobId, String searchText) {
    String pattern = String.isBlank(searchText)
      ? '%'
      : '%' + searchText.trim() + '%';
    List<String> lines = new List<String>();
    for (Job_Applicant__c applicant : [
      SELECT
        Id,
        Score__c,
        Candidate__c,
        Candidate__r.Name,
        Candidate__r.Current_Title__c,
        Candidate__r.Years_Experience__c,
        Candidate__r.Country__c
      FROM Job_Applicant__c
      WHERE Job__c = :jobId AND Candidate__r.Name LIKE :pattern
      WITH USER_MODE
      ORDER BY Score__c DESC NULLS LAST, Candidate__r.Name
      LIMIT :MAX_RESULTS
    ]) {
      lines.add(
        describe(applicant.Candidate__r) +
          ' | score: ' +
          (applicant.Score__c == null
            ? 'not scored'
            : String.valueOf(applicant.Score__c.intValue())) +
          ' | candidateId: ' +
          applicant.Candidate__c +
          ' | applicantId: ' +
          applicant.Id
      );
    }
    return lines.isEmpty()
      ? 'This job has no matching applicants.'
      : String.join(lines, '\n');
  }

  private static String describe(Candidate__c candidate) {
    return candidate.Name +
      ' | ' +
      (candidate.Current_Title__c == null
        ? 'title not found in CV'
        : candidate.Current_Title__c) +
      ' | ' +
      (candidate.Years_Experience__c == null
        ? 'years not found in CV'
        : candidate.Years_Experience__c + ' years') +
      ' | ' +
      (candidate.Country__c == null
        ? 'country not found'
        : candidate.Country__c);
  }
}
