/**
 * Careers portal (Experience Cloud, guest user): browse open jobs, read one job, apply.
 *
 * Reads run with sharing and in user mode: the guest sees exactly what the Careers_Guest
 * permission set and the guest sharing rules allow (jobs and skills, nothing else).
 * A job is open while its due date is today or later, or when it has no due date.
 *
 * apply() is the only write. It hands over to CareersApplicationService, which validates the
 * input and creates the records in system mode (the guest has no create access on anything).
 */
public with sharing class CareersController {
  @TestVisible
  private static final Integer PAGE_SIZE = 10;
  private static final Integer MAX_OFFSET = 2000; // SOQL OFFSET limit
  private static final String MUST_HAVE = 'Must Have';
  private static final String LOG_TAG = 'Careers';

  public class JobSummary {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String title;
    @AuraEnabled
    public String location;
    @AuraEnabled
    public Decimal minYears;
    @AuraEnabled
    public Date dueDate;
  }

  public class JobDetail {
    @AuraEnabled
    public JobSummary job;
    @AuraEnabled
    public String description;
    @AuraEnabled
    public List<String> mustHaveSkills = new List<String>();
    @AuraEnabled
    public List<String> niceToHaveSkills = new List<String>();
  }

  public class JobPage {
    @AuraEnabled
    public Integer total;
    @AuraEnabled
    public Integer pageSize = PAGE_SIZE;
    @AuraEnabled
    public List<JobSummary> jobs = new List<JobSummary>();
  }

  public class FilterOptions {
    @AuraEnabled
    public List<String> locations = new List<String>();
    @AuraEnabled
    public List<String> skills = new List<String>();
  }

  /**
   * Open jobs matching the filters, soonest due date first.
   * keyword: matches title, location or a required skill. locations / skills: any of them.
   * years: the candidate's experience, keeps jobs whose minimum is at most that.
   */
  @AuraEnabled
  public static JobPage searchJobs(
    String keyword,
    List<String> locations,
    List<String> skills,
    Decimal years,
    Integer pageNumber
  ) {
    try {
      Date today = Date.today();
      List<String> conditions = new List<String>{
        '(Due_Date__c = NULL OR Due_Date__c >= :today)'
      };

      String likeKeyword = String.isBlank(keyword)
        ? null
        : '%' + escapeLike(keyword.trim()) + '%';
      Set<Id> keywordSkillJobIds = new Set<Id>();
      if (likeKeyword != null) {
        // A semi-join can't be combined with OR, so the skill match is a separate query.
        for (Job_Skill__c jobSkill : [
          SELECT Job__c
          FROM Job_Skill__c
          WHERE Skill__r.Name LIKE :likeKeyword
          WITH USER_MODE
        ]) {
          keywordSkillJobIds.add(jobSkill.Job__c);
        }
        conditions.add(
          '(Name LIKE :likeKeyword OR Location__c LIKE :likeKeyword OR Id IN :keywordSkillJobIds)'
        );
      }

      List<String> safeLocations = clean(locations);
      if (!safeLocations.isEmpty()) {
        conditions.add('Location__c IN :safeLocations');
      }

      List<String> safeSkills = clean(skills);
      if (!safeSkills.isEmpty()) {
        conditions.add(
          'Id IN (SELECT Job__c FROM Job_Skill__c WHERE Skill__r.Name IN :safeSkills)'
        );
      }

      if (years != null && years >= 0) {
        conditions.add(
          '(Min_Years_Experience__c = NULL OR Min_Years_Experience__c <= :years)'
        );
      }

      Integer page = pageNumber == null || pageNumber < 1 ? 1 : pageNumber;
      Integer offsetSize = Math.min((page - 1) * PAGE_SIZE, MAX_OFFSET);
      Integer pageSize = PAGE_SIZE;
      Map<String, Object> binds = new Map<String, Object>{
        'today' => today,
        'likeKeyword' => likeKeyword,
        'keywordSkillJobIds' => keywordSkillJobIds,
        'safeLocations' => safeLocations,
        'safeSkills' => safeSkills,
        'years' => years,
        'pageSize' => pageSize,
        'offsetSize' => offsetSize
      };
      // Only fixed condition strings are joined: every user value is a bind variable.
      String whereClause = ' WHERE ' + String.join(conditions, ' AND ');

      JobPage result = new JobPage();
      result.total = Database.countQueryWithBinds(
        'SELECT COUNT() FROM Job__c' + whereClause,
        binds,
        AccessLevel.USER_MODE
      );
      for (
        Job__c job : (List<Job__c>) Database.queryWithBinds(
          'SELECT Id, Name, Location__c, Min_Years_Experience__c, Due_Date__c FROM Job__c' +
            whereClause +
            ' ORDER BY Due_Date__c ASC NULLS LAST, Name ASC LIMIT :pageSize OFFSET :offsetSize',
          binds,
          AccessLevel.USER_MODE
        )
      ) {
        result.jobs.add(toSummary(job));
      }
      return result;
    } catch (Exception ex) {
      throw logAndHide('Job search failed', ex);
    }
  }

  /** Values for the filter panel, taken from open jobs only. */
  @AuraEnabled
  public static FilterOptions getFilterOptions() {
    try {
      Date today = Date.today();
      FilterOptions options = new FilterOptions();
      for (AggregateResult row : [
        SELECT Location__c location
        FROM Job__c
        WHERE
          (Due_Date__c = NULL
          OR Due_Date__c >= :today)
          AND Location__c != NULL
        WITH USER_MODE
        GROUP BY Location__c
        ORDER BY Location__c
      ]) {
        options.locations.add((String) row.get('location'));
      }
      for (AggregateResult row : [
        SELECT Skill__r.Name skill
        FROM Job_Skill__c
        WHERE Job__r.Due_Date__c = NULL OR Job__r.Due_Date__c >= :today
        WITH USER_MODE
        GROUP BY Skill__r.Name
        ORDER BY Skill__r.Name
      ]) {
        options.skills.add((String) row.get('skill'));
      }
      return options;
    } catch (Exception ex) {
      throw logAndHide('Loading the filters failed', ex);
    }
  }

  /** One open job with its skills. Closed or unknown jobs return a friendly error. */
  @AuraEnabled
  public static JobDetail getJob(Id jobId) {
    try {
      Date today = Date.today();
      List<Job__c> jobs = [
        SELECT
          Id,
          Name,
          Location__c,
          Min_Years_Experience__c,
          Due_Date__c,
          Description__c,
          (
            SELECT Skill__r.Name, Importance__c
            FROM Job_Skills__r
            ORDER BY Skill__r.Name
          )
        FROM Job__c
        WHERE Id = :jobId AND (Due_Date__c = NULL OR Due_Date__c >= :today)
        WITH USER_MODE
      ];
      if (jobs.isEmpty()) {
        throw auraError('This job is no longer open.');
      }
      JobDetail detail = new JobDetail();
      detail.job = toSummary(jobs[0]);
      detail.description = jobs[0].Description__c;
      for (Job_Skill__c jobSkill : jobs[0].Job_Skills__r) {
        (jobSkill.Importance__c == MUST_HAVE
            ? detail.mustHaveSkills
            : detail.niceToHaveSkills)
          .add(jobSkill.Skill__r.Name);
      }
      return detail;
    } catch (AuraHandledException ex) {
      throw ex;
    } catch (Exception ex) {
      throw logAndHide('Loading job ' + jobId + ' failed', ex);
    }
  }

  /** Submits an application. Never throws for bad input: the result carries the message to show. */
  @AuraEnabled
  public static CareersApplicationService.Result apply(
    CareersApplicationService.Application application
  ) {
    return new CareersApplicationService().apply(application);
  }

  private static JobSummary toSummary(Job__c job) {
    JobSummary summary = new JobSummary();
    summary.id = job.Id;
    summary.title = job.Name;
    summary.location = job.Location__c;
    summary.minYears = job.Min_Years_Experience__c;
    summary.dueDate = job.Due_Date__c;
    return summary;
  }

  private static List<String> clean(List<String> values) {
    List<String> cleaned = new List<String>();
    if (values == null) {
      return cleaned;
    }
    for (String value : values) {
      if (String.isNotBlank(value)) {
        cleaned.add(value.trim());
      }
    }
    return cleaned;
  }

  /** % and _ are wildcards in LIKE: a candidate typing them should match them literally. */
  @TestVisible
  private static String escapeLike(String value) {
    return value.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_');
  }

  /** Logs the real error, shows the visitor a generic one (no internals on a public site). */
  private static AuraHandledException logAndHide(String message, Exception ex) {
    Logger.error(message).setExceptionDetails(ex).addTag(LOG_TAG);
    Logger.saveLog();
    return auraError('Something went wrong. Please try again later.');
  }

  private static AuraHandledException auraError(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    return error;
  }
}
