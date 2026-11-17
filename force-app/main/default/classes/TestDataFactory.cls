/**
 * Builds test records, so every test class creates data the same way and only states what
 * matters to it.
 *
 *  - new*:    builds the record without inserting it (to set more fields first).
 *  - create*: inserts it and returns it.
 *  - Skills are looked up by name before being created, so several helpers can name the same skill.
 *  - Candidates get a unique email (Email__c is unique and required) unless the test sets one.
 */
@IsTest
public class TestDataFactory {
  public static final String EMAIL_DOMAIN = '@test.cvreview';
  private static Integer sequence = 0;

  // ---------- Skills ----------

  /** Skills by name: existing ones are reused, missing ones created. */
  public static Map<String, Skill__c> createSkills(List<String> names) {
    Map<String, Skill__c> skills = new Map<String, Skill__c>();
    for (Skill__c skill : [
      SELECT Id, Name
      FROM Skill__c
      WHERE Name IN :names
    ]) {
      skills.put(skill.Name, skill);
    }
    List<Skill__c> created = new List<Skill__c>();
    for (String name : names) {
      if (!skills.containsKey(name)) {
        Skill__c skill = new Skill__c(Name = name);
        skills.put(name, skill);
        created.add(skill);
      }
    }
    insert created;
    return skills;
  }

  // ---------- Jobs ----------

  public static Job__c newJob(String name) {
    return new Job__c(Name = name);
  }

  public static Job__c createJob(String name) {
    Job__c job = newJob(name);
    insert job;
    return job;
  }

  /** A job with its required skills. Pass null or an empty list when there are none. */
  public static Job__c createJob(
    String name,
    Decimal minYears,
    List<String> mustHave,
    List<String> niceToHave
  ) {
    Job__c job = newJob(name);
    job.Min_Years_Experience__c = minYears;
    insert job;
    addJobSkills(job.Id, mustHave, Constants.IMPORTANCE_MUST_HAVE);
    addJobSkills(job.Id, niceToHave, Constants.IMPORTANCE_NICE_TO_HAVE);
    return job;
  }

  public static List<Job_Skill__c> addJobSkills(
    Id jobId,
    List<String> names,
    String importance
  ) {
    List<Job_Skill__c> jobSkills = new List<Job_Skill__c>();
    if (names == null || names.isEmpty()) {
      return jobSkills;
    }
    for (Skill__c skill : createSkills(names).values()) {
      jobSkills.add(
        new Job_Skill__c(
          Job__c = jobId,
          Skill__c = skill.Id,
          Importance__c = importance
        )
      );
    }
    insert jobSkills;
    return jobSkills;
  }

  // ---------- Candidates ----------

  /** A candidate with a unique email, not inserted. */
  public static Candidate__c newCandidate(String name) {
    return new Candidate__c(Name = name, Email__c = uniqueEmail(name));
  }

  public static Candidate__c createCandidate(String name) {
    Candidate__c candidate = newCandidate(name);
    insert candidate;
    return candidate;
  }

  /** A candidate with years of experience and skills. */
  public static Candidate__c createCandidate(
    String name,
    Decimal years,
    List<String> skills
  ) {
    Candidate__c candidate = newCandidate(name);
    candidate.Years_Experience__c = years;
    insert candidate;
    addCandidateSkills(candidate.Id, skills);
    return candidate;
  }

  public static List<Candidate_Skill__c> addCandidateSkills(
    Id candidateId,
    List<String> names
  ) {
    List<Candidate_Skill__c> links = new List<Candidate_Skill__c>();
    if (names == null || names.isEmpty()) {
      return links;
    }
    for (Skill__c skill : createSkills(names).values()) {
      links.add(
        new Candidate_Skill__c(Candidate__c = candidateId, Skill__c = skill.Id)
      );
    }
    insert links;
    return links;
  }

  public static Extraction_Flag__c newFlag(
    Id candidateId,
    String type,
    String field,
    String detail
  ) {
    return new Extraction_Flag__c(
      Candidate__c = candidateId,
      Type__c = type,
      Field__c = field,
      Detail__c = detail
    );
  }

  public static String uniqueEmail(String name) {
    String base = name == null
      ? 'candidate'
      : name.toLowerCase().replaceAll('[^a-z0-9]', '');
    return (String.isBlank(base) ? 'candidate' : base.left(40)) +
      '.' +
      (++sequence) +
      EMAIL_DOMAIN;
  }

  // ---------- Applications ----------

  public static Job_Applicant__c newApplicant(Id jobId, Id candidateId) {
    return new Job_Applicant__c(Job__c = jobId, Candidate__c = candidateId);
  }

  /** score: null for an application not scored yet. */
  public static Job_Applicant__c createApplicant(
    Id jobId,
    Id candidateId,
    Decimal score
  ) {
    Job_Applicant__c applicant = newApplicant(jobId, candidateId);
    applicant.Score__c = score;
    insert applicant;
    return applicant;
  }

  // ---------- Files ----------

  /** A file attached to the record (parentId may be null), with the fields the services read. */
  public static ContentVersion createFile(
    Id parentId,
    String fileName,
    Blob data
  ) {
    ContentVersion version = new ContentVersion(
      Title = fileName.substringBeforeLast('.'),
      PathOnClient = fileName,
      VersionData = data,
      FirstPublishLocationId = parentId
    );
    insert version;
    return [
      SELECT Id, ContentDocumentId, FileExtension, FileType, Title
      FROM ContentVersion
      WHERE Id = :version.Id
    ];
  }

  public static ContentVersion createFile(
    Id parentId,
    String fileName,
    String text
  ) {
    return createFile(parentId, fileName, Blob.valueOf(text));
  }

  // ---------- Users ----------

  /** A Standard User without the app's permission set. */
  public static User createUser() {
    Profile standardUser = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    String username =
      'user' +
      (++sequence) +
      '.' +
      Crypto.getRandomInteger() +
      EMAIL_DOMAIN;
    User user = new User(
      Alias = 'tuser',
      Email = username,
      Username = username,
      LastName = 'Recruiter',
      ProfileId = standardUser.Id,
      TimeZoneSidKey = 'Europe/Paris',
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US'
    );
    // Setup objects in their own context, to avoid mixed DML with the test records.
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert user;
    }
    return user;
  }

  /** A Standard User with the Clouding_HR permission set (a recruiter). */
  public static User createRecruiter() {
    User recruiter = createUser();
    PermissionSet permissionSet = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = 'Clouding_HR'
      LIMIT 1
    ];
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new PermissionSetAssignment(
        AssigneeId = recruiter.Id,
        PermissionSetId = permissionSet.Id
      );
    }
    return recruiter;
  }
}
