/**
 * Creates the Candidate Card of existing candidates: reads each candidate's CV and fills the
 * card fields that are still empty, adds the skills found in the CV, and records the Missing /
 * Inferred / Conflict flags. Then scores the candidate's unscored applications.
 *
 * The candidate already exists (created by the careers portal or by a recruiter) with its CV in
 * Files. This service never creates a candidate and never overwrites a value already on the
 * record: when the CV says something else, the record value is kept and a Conflict flag shows both.
 *
 * How a CV fills the card:
 *  1. The CV file: the newest PDF / DOCX / TXT file of the candidate, preferring the files whose
 *     title starts with "CV" (the portal names the CV "CV - <name> - <file>", other documents
 *     "Document - ..."). The profile photo is never used.
 *  2. CvTextReader gets the text (the AI reads PDFs, Apex reads DOCX). It is saved in CV_Text__c,
 *     the source the questions and the comparison quote from.
 *  3. The AI (template CV_Extract_Card) returns the card as JSON, with a quote for every skill and
 *     the issues it found inside the CV (e.g. two different years of experience).
 *  4. Apex validates the answer, fills the empty fields, and adds the flags it can check itself:
 *     - Missing: an important field that is empty on the record and not in the CV either.
 *     - Conflict: the CV disagrees with a value already on the record.
 *     - Inferred: a skill the AI deduced instead of reading it.
 *     The flags of a previous run are replaced: they describe the latest reading of the CV.
 *  5. The unscored applications of the candidate are scored.
 *
 * Several candidates: at most MAX_CANDIDATES_PER_REQUEST per request (each takes one or two AI
 * calls, and a request has a time limit). The others are listed as not done, the recruiter asks
 * again for them.
 *
 * Runs with sharing, queries and DML in user mode. AI calls come first, saving afterwards (no
 * DML is allowed before a callout). Each candidate is saved in its own savepoint: one bad CV
 * doesn't stop the others.
 */
public with sharing class CvExtractionService {
  /** Candidates done in one request; the others are listed as not done. */
  public static final Integer MAX_CANDIDATES_PER_REQUEST = 3;
  /** Applicants of a job looked at in one request ("fill the cards of this job's applicants"). */
  @TestVisible
  private static final Integer MAX_JOB_APPLICANTS = 200;
  @TestVisible
  private static final Integer MAX_SKILLS = 40;
  private static final Integer MAX_KNOWN_SKILLS = 300;
  private static final Decimal YEARS_TOLERANCE = 0.5;

  /** Card fields the AI may flag, with the label stored in Extraction_Flag__c.Field__c. */
  private static final Map<String, String> FIELD_LABELS = new Map<String, String>{
    'fullName' => 'Name',
    'email' => 'Email',
    'phone' => 'Phone',
    'country' => 'Country',
    'currentTitle' => 'Current Title',
    'summary' => 'Summary',
    'yearsExperience' => 'Years of Experience',
    'experience' => 'Experience',
    'education' => 'Education',
    'achievements' => 'Achievements',
    'skills' => 'Skills',
    'cv' => 'CV'
  };

  /** Text fields filled from the CV, with their max length. */
  private static final Map<String, SObjectField> TEXT_FIELDS = new Map<String, SObjectField>{
    'fullName' => Candidate__c.Name,
    'email' => Candidate__c.Email__c,
    'phone' => Candidate__c.Phone__c,
    'country' => Candidate__c.Country__c,
    'currentTitle' => Candidate__c.Current_Title__c,
    'summary' => Candidate__c.Summary__c,
    'experience' => Candidate__c.Experience__c,
    'education' => Candidate__c.Education__c,
    'achievements' => Candidate__c.Achievements__c
  };

  /** Short fields compared with the CV (long texts are worded differently anyway). */
  private static final Set<String> COMPARED_FIELDS = new Set<String>{
    'fullName',
    'email',
    'phone',
    'country',
    'currentTitle'
  };

  /** Fields reported as Missing when empty on the record and not in the CV. */
  private static final List<String> EXPECTED_FIELDS = new List<String>{
    'email',
    'phone',
    'country',
    'currentTitle',
    'yearsExperience',
    'experience',
    'education'
  };

  public class Outcome {
    public Id candidateId;
    public String candidateName;
    public String fileName;
    public Boolean success = false;
    public Integer filledCount = 0;
    public Integer skillsAdded = 0;
    public Integer missingCount = 0;
    public Integer inferredCount = 0;
    public Integer conflictCount = 0;
    /** One line for the recruiter (shown by the agent). */
    public String message;
  }

  public class FillResult {
    public List<Outcome> outcomes = new List<Outcome>();
    /** Names of the candidates over the limit, not done in this request. */
    public List<String> notDone = new List<String>();
    /** Job applicants skipped because their card was already created from a CV. */
    public Integer alreadyDoneCount = 0;
  }

  /** One candidate and its CV. */
  private class Work {
    Candidate__c candidate;
    ContentVersion version;
    CvTextReader.CvText cv;
    Map<String, Object> card;
    Outcome outcome = new Outcome();
  }

  // =====================================================================================
  // Entry points
  // =====================================================================================

  /**
   * Fills the card of these candidates from their CV: the first MAX_CANDIDATES_PER_REQUEST, the
   * others are returned in notDone.
   */
  public static FillResult fillCards(List<Id> candidateIds) {
    FillResult result = new FillResult();
    List<Id> now = new List<Id>();
    List<Id> later = new List<Id>();
    // A Set removes the duplicates.
    List<Id> uniqueIds = new List<Id>(new Set<Id>(candidateIds));
    for (Id candidateId : uniqueIds) {
      if (now.size() < MAX_CANDIDATES_PER_REQUEST) {
        now.add(candidateId);
      } else {
        later.add(candidateId);
      }
    }
    result.outcomes = fill(now);
    for (Candidate__c candidate : [
      SELECT Name
      FROM Candidate__c
      WHERE Id IN :later
      WITH USER_MODE
      ORDER BY Name
    ]) {
      result.notDone.add(candidate.Name);
    }
    return result;
  }

  /** Fills the cards of a job's applicants whose card was not created from a CV yet. */
  public static FillResult fillJobApplicants(Id jobId) {
    List<Id> pending = new List<Id>();
    Integer alreadyDone = 0;
    // CV_Text__c is a long text: it can't be filtered in SOQL, so the check is done here.
    for (Job_Applicant__c applicant : [
      SELECT Candidate__c, Candidate__r.CV_Text__c
      FROM Job_Applicant__c
      WHERE Job__c = :jobId
      WITH USER_MODE
      ORDER BY CreatedDate
      LIMIT :MAX_JOB_APPLICANTS
    ]) {
      if (String.isBlank(applicant.Candidate__r.CV_Text__c)) {
        pending.add(applicant.Candidate__c);
      } else {
        alreadyDone++;
      }
    }
    FillResult result = fillCards(pending);
    result.alreadyDoneCount = alreadyDone;
    return result;
  }

  // =====================================================================================
  // Processing
  // =====================================================================================

  private static List<Outcome> fill(List<Id> candidateIds) {
    List<Outcome> outcomes = new List<Outcome>();
    if (candidateIds.isEmpty()) {
      return outcomes;
    }
    Map<Id, Candidate__c> candidates = queryCandidates(candidateIds);
    Map<Id, ContentVersion> cvByCandidate = latestCvs(candidates.values());

    // One Work per candidate that has a CV. The others get their message now.
    List<Work> works = new List<Work>();
    for (Id candidateId : candidateIds) {
      Candidate__c candidate = candidates.get(candidateId);
      Work work = new Work();
      work.candidate = candidate;
      work.outcome.candidateId = candidateId;
      outcomes.add(work.outcome);
      if (candidate == null) {
        work.outcome.message =
          'Candidate ' +
          candidateId +
          ' not found or not accessible.';
      } else if (!cvByCandidate.containsKey(candidateId)) {
        work.outcome.candidateName = candidate.Name;
        work.outcome.message =
          candidate.Name +
          ' has no CV file. Upload one in the Files of the candidate first.';
      } else {
        work.outcome.candidateName = candidate.Name;
        work.version = cvByCandidate.get(candidateId);
        work.outcome.fileName = work.version.Title;
        works.add(work);
      }
    }
    if (works.isEmpty()) {
      return outcomes;
    }

    // 1. AI calls only (no DML before a callout).
    readCards(works);
    // 2. Save each candidate on its own.
    Set<Id> savedCandidateIds = saveCards(works);
    // 3. Score the applications of the candidates whose card changed.
    addScoringNotes(works, score(savedCandidateIds));
    Logger.saveLog();
    return outcomes;
  }

  private static Map<Id, Candidate__c> queryCandidates(List<Id> candidateIds) {
    return new Map<Id, Candidate__c>(
      [
        SELECT
          Id,
          Name,
          Email__c,
          Phone__c,
          Country__c,
          Current_Title__c,
          Summary__c,
          Years_Experience__c,
          Experience__c,
          Education__c,
          Achievements__c,
          Photo_Version_Id__c
        FROM Candidate__c
        WHERE Id IN :candidateIds
        WITH USER_MODE
      ]
    );
  }

  /** Reads the CV text and asks the AI for the card. No DML here (callouts only). */
  private static void readCards(List<Work> works) {
    String knownSkills = knownSkills();
    for (Work work : works) {
      try {
        work.cv = CvTextReader.read(work.version);
        if (work.cv.text != null) {
          work.card = extractCard(work.cv.text, knownSkills);
        }
      } catch (Exception ex) {
        work.cv = null;
        work.outcome.message =
          'The AI could not read the CV of ' +
          work.candidate.Name +
          ': ' +
          ex.getMessage();
        Logger.error('CV extraction failed for candidate ' + work.candidate.Id)
          .setExceptionDetails(ex)
          .addTag(Constants.LOG_TAG_CV_EXTRACTION);
      }
    }
  }

  /** Asks the AI for the card of this CV text, as a JSON object. */
  private static Map<String, Object> extractCard(
    String cvText,
    String knownSkills
  ) {
    Map<String, Object> inputs = new Map<String, Object>{
      'CvText' => cvText,
      'KnownSkills' => knownSkills,
      'Today' => String.valueOf(Date.today())
    };
    String answer = AiPrompt.run(Constants.TEMPLATE_EXTRACT_CARD, inputs);
    return AiPrompt.parseJsonObject(answer);
  }

  /** Saves each candidate in its own savepoint. Returns the Ids of the saved candidates. */
  private static Set<Id> saveCards(List<Work> works) {
    Set<Id> savedCandidateIds = new Set<Id>();
    for (Work work : works) {
      if (work.cv == null) {
        continue; // AI error, already reported
      }
      Savepoint savepoint = Database.setSavepoint();
      try {
        save(work);
        savedCandidateIds.add(work.candidate.Id);
      } catch (Exception ex) {
        Database.rollback(savepoint);
        work.outcome.success = false;
        work.outcome.message =
          'Could not save the card of ' +
          work.candidate.Name +
          ': ' +
          ex.getMessage();
        Logger.error(
            'Saving the card failed for candidate ' + work.candidate.Id
          )
          .setExceptionDetails(ex)
          .addTag(Constants.LOG_TAG_CV_EXTRACTION);
      }
    }
    return savedCandidateIds;
  }

  /** Adds the scoring note to the message of each saved candidate, and logs the message. */
  private static void addScoringNotes(
    List<Work> works,
    Map<Id, String> scoringNotes
  ) {
    for (Work work : works) {
      Id candidateId = work.candidate.Id;
      if (work.outcome.success && scoringNotes.containsKey(candidateId)) {
        work.outcome.message += ' ' + scoringNotes.get(candidateId);
      }
      Logger.info('Candidate card: ' + work.outcome.message)
        .addTag(Constants.LOG_TAG_CV_EXTRACTION);
    }
  }

  private static void save(Work work) {
    Candidate__c candidate = work.candidate;
    if (work.card == null) {
      // Unreadable CV: keep the card as it is, replace only the previous CV flag.
      replaceFlags(
        candidate.Id,
        new List<Extraction_Flag__c>{
          flag(Constants.FLAG_MISSING, 'CV', work.cv.problem)
        },
        false
      );
      work.outcome.missingCount = 1;
      work.outcome.message = candidate.Name + ': ' + work.cv.problem;
      return;
    }

    List<Extraction_Flag__c> flags = new List<Extraction_Flag__c>();
    Candidate__c updates = new Candidate__c(
      Id = candidate.Id,
      CV_Text__c = work.cv.text
    );
    work.outcome.filledCount = fillFields(candidate, work.card, updates, flags);
    update as user updates;

    List<Map<String, Object>> skills = AiPrompt.objects(work.card, 'skills');
    Integer skillCount = addSkills(candidate.Id, skills, flags, work.outcome);
    flags.addAll(aiFlags(work.card));
    flags.addAll(missingFlags(candidate, work.card, skillCount, flags));
    if (work.cv.truncated) {
      flags.add(
        flag(
          Constants.FLAG_MISSING,
          'CV',
          'The CV is very long: only the beginning was read.'
        )
      );
    }
    replaceFlags(candidate.Id, flags, true);

    work.outcome.success = true;
    countFlags(flags, work.outcome);
    work.outcome.message = summary(candidate.Name, work.outcome, skillCount);
  }

  private static void countFlags(
    List<Extraction_Flag__c> flags,
    Outcome outcome
  ) {
    for (Extraction_Flag__c item : flags) {
      if (item.Type__c == Constants.FLAG_MISSING) {
        outcome.missingCount++;
      } else if (item.Type__c == Constants.FLAG_INFERRED) {
        outcome.inferredCount++;
      } else {
        outcome.conflictCount++;
      }
    }
  }

  /**
   * One line for the recruiter, e.g. "Card of Jane: 3 field(s) filled, 2 skill(s) added
   * (5 in total); 1 missing, 0 inferred, 0 conflicting."
   */
  private static String summary(
    String candidateName,
    Outcome outcome,
    Integer skillCount
  ) {
    String fields = outcome.filledCount + ' field(s) filled, ';
    String skills = outcome.skillsAdded + ' skill(s) added (';
    skills += skillCount + ' in total); ';
    String counts = outcome.missingCount + ' missing, ';
    counts += outcome.inferredCount + ' inferred, ';
    counts += outcome.conflictCount + ' conflicting.';
    return 'Card of ' + candidateName + ': ' + fields + skills + counts;
  }

  /**
   * Fills the empty fields of the candidate from the CV (into updates) and flags the values the
   * CV contradicts. Returns the number of fields filled.
   */
  private static Integer fillFields(
    Candidate__c candidate,
    Map<String, Object> card,
    Candidate__c updates,
    List<Extraction_Flag__c> flags
  ) {
    Integer filled = 0;
    for (String key : TEXT_FIELDS.keySet()) {
      SObjectField field = TEXT_FIELDS.get(key);
      String cvValue = AiPrompt.text(card, key);
      if (key == 'email') {
        cvValue = normalizeEmail(cvValue);
      }
      if (cvValue == null) {
        continue;
      }
      String recordValue = (String) candidate.get(field);
      if (String.isBlank(recordValue)) {
        Integer maxLength = field.getDescribe().getLength();
        updates.put(field, cvValue.left(maxLength));
        filled++;
      } else if (
        COMPARED_FIELDS.contains(key) &&
        comparable(key, recordValue) != comparable(key, cvValue)
      ) {
        flags.add(conflict(key, recordValue, cvValue));
      }
    }

    Decimal cvYears = validYears(AiPrompt.num(card, 'yearsExperience'));
    if (cvYears != null) {
      if (candidate.Years_Experience__c == null) {
        updates.Years_Experience__c = cvYears;
        filled++;
      } else if (
        (candidate.Years_Experience__c - cvYears).abs() > YEARS_TOLERANCE
      ) {
        flags.add(
          conflict(
            'yearsExperience',
            String.valueOf(candidate.Years_Experience__c),
            String.valueOf(cvYears)
          )
        );
      }
    }
    return filled;
  }

  private static Extraction_Flag__c conflict(
    String key,
    String recordValue,
    String cvValue
  ) {
    return flag(
      Constants.FLAG_CONFLICT,
      FIELD_LABELS.get(key),
      'Record: "' +
        recordValue.left(200) +
        '", CV: "' +
        cvValue.left(200) +
        '". The record value is kept.'
    );
  }

  private static String comparable(String key, String value) {
    String result = value.trim().toLowerCase();
    // Phone numbers: compare digits only ("+212 600-000" = "212600000").
    if (key == 'phone') {
      return result.replaceAll('[^0-9]', '');
    }
    return result.replaceAll('\\s+', ' ');
  }

  /** Flags the AI found inside the CV. Unknown types are dropped, not guessed. */
  private static List<Extraction_Flag__c> aiFlags(Map<String, Object> card) {
    List<Extraction_Flag__c> flags = new List<Extraction_Flag__c>();
    Set<String> types = Constants.FLAG_TYPES;
    for (Map<String, Object> item : AiPrompt.objects(card, 'flags')) {
      String type = AiPrompt.text(item, 'type');
      String detail = AiPrompt.text(item, 'detail');
      if (type == null || detail == null) {
        continue;
      }
      type = type.toLowerCase().capitalize();
      if (!types.contains(type)) {
        continue;
      }
      String field = AiPrompt.text(item, 'field');
      flags.add(flag(type, fieldLabel(field), detail));
    }
    return flags;
  }

  /** The label of a card field, or the value itself when it is not a known field. */
  private static String fieldLabel(String field) {
    if (FIELD_LABELS.containsKey(field)) {
      return FIELD_LABELS.get(field);
    }
    return field;
  }

  /**
   * Missing flags Apex can check itself: empty on the record and not in the CV either, unless a
   * flag already covers the field.
   */
  private static List<Extraction_Flag__c> missingFlags(
    Candidate__c candidate,
    Map<String, Object> card,
    Integer skillCount,
    List<Extraction_Flag__c> existing
  ) {
    Set<String> flagged = new Set<String>();
    for (Extraction_Flag__c item : existing) {
      if (item.Type__c == Constants.FLAG_MISSING) {
        flagged.add(item.Field__c);
      }
    }
    List<Extraction_Flag__c> flags = new List<Extraction_Flag__c>();
    for (String key : EXPECTED_FIELDS) {
      String label = FIELD_LABELS.get(key);
      if (isMissing(candidate, card, key) && !flagged.contains(label)) {
        flags.add(flag(Constants.FLAG_MISSING, label, 'Not found in CV.'));
      }
    }
    if (skillCount == 0 && !flagged.contains('Skills')) {
      flags.add(
        flag(Constants.FLAG_MISSING, 'Skills', 'No skills found in CV.')
      );
    }
    return flags;
  }

  /** True when the field is empty on the record and not in the CV either. */
  private static Boolean isMissing(
    Candidate__c candidate,
    Map<String, Object> card,
    String key
  ) {
    if (key == 'yearsExperience') {
      Decimal cvYears = validYears(AiPrompt.num(card, key));
      return candidate.Years_Experience__c == null && cvYears == null;
    }
    String recordValue = (String) candidate.get(TEXT_FIELDS.get(key));
    String cvValue = AiPrompt.text(card, key);
    return String.isBlank(recordValue) && cvValue == null;
  }

  /**
   * Adds the skills found in the CV that the candidate doesn't have yet (existing skills stay).
   * Skill__c records are matched by name (case-insensitive), new names create a Skill__c.
   * Inferred skills get a flag. Returns the candidate's number of skills after the change.
   */
  private static Integer addSkills(
    Id candidateId,
    List<Map<String, Object>> skills,
    List<Extraction_Flag__c> flags,
    Outcome outcome
  ) {
    Map<String, String> nameByKey = cvSkillNames(skills, flags);
    Map<String, Id> skillIdByKey = findOrCreateSkills(nameByKey);

    Set<Id> current = new Set<Id>();
    for (Candidate_Skill__c link : [
      SELECT Skill__c
      FROM Candidate_Skill__c
      WHERE Candidate__c = :candidateId
      WITH USER_MODE
    ]) {
      current.add(link.Skill__c);
    }
    List<Candidate_Skill__c> links = new List<Candidate_Skill__c>();
    for (Id skillId : new Set<Id>(skillIdByKey.values())) {
      if (!current.contains(skillId)) {
        links.add(
          new Candidate_Skill__c(Candidate__c = candidateId, Skill__c = skillId)
        );
      }
    }
    insert as user links;
    outcome.skillsAdded = links.size();
    return current.size() + links.size();
  }

  /**
   * The skill names of the CV by lower-case name (duplicates removed, at most MAX_SKILLS).
   * Adds an Inferred flag for each skill the AI deduced.
   */
  private static Map<String, String> cvSkillNames(
    List<Map<String, Object>> skills,
    List<Extraction_Flag__c> flags
  ) {
    Map<String, String> nameByKey = new Map<String, String>();
    for (Map<String, Object> skill : skills) {
      String name = limitTo(AiPrompt.text(skill, 'name'), 80);
      if (name == null || nameByKey.size() == MAX_SKILLS) {
        continue;
      }
      String key = name.toLowerCase();
      if (nameByKey.containsKey(key)) {
        continue;
      }
      nameByKey.put(key, name);
      if (AiPrompt.bool(skill, 'inferred')) {
        String evidence = AiPrompt.text(skill, 'evidence');
        String detail = inferredDetail(name, evidence);
        flags.add(flag(Constants.FLAG_INFERRED, 'Skills', detail));
      }
    }
    return nameByKey;
  }

  private static String inferredDetail(String name, String evidence) {
    String detail = name + ' is not written in the CV, it was deduced';
    if (evidence == null) {
      return detail + '.';
    }
    return detail + ' from: "' + evidence + '"';
  }

  /** Skill__c Id by lower-case name. Names not found create a new Skill__c. */
  private static Map<String, Id> findOrCreateSkills(
    Map<String, String> nameByKey
  ) {
    Map<String, Id> skillIdByKey = new Map<String, Id>();
    List<String> names = nameByKey.values();
    for (Skill__c skill : [
      SELECT Id, Name
      FROM Skill__c
      WHERE Name IN :names
      WITH USER_MODE
    ]) {
      skillIdByKey.put(skill.Name.toLowerCase(), skill.Id);
    }
    List<Skill__c> newSkills = new List<Skill__c>();
    for (String key : nameByKey.keySet()) {
      if (!skillIdByKey.containsKey(key)) {
        newSkills.add(new Skill__c(Name = nameByKey.get(key)));
      }
    }
    insert as user newSkills;
    for (Skill__c skill : newSkills) {
      skillIdByKey.put(skill.Name.toLowerCase(), skill.Id);
    }
    return skillIdByKey;
  }

  /** all = true: the CV was read again, every old flag goes. false: only the old CV flag goes. */
  private static void replaceFlags(
    Id candidateId,
    List<Extraction_Flag__c> flags,
    Boolean all
  ) {
    List<Extraction_Flag__c> old;
    if (all) {
      old = [
        SELECT Id
        FROM Extraction_Flag__c
        WHERE Candidate__c = :candidateId
        WITH USER_MODE
      ];
    } else {
      old = [
        SELECT Id
        FROM Extraction_Flag__c
        WHERE Candidate__c = :candidateId AND Field__c = 'CV'
        WITH USER_MODE
      ];
    }
    delete as user old;
    for (Extraction_Flag__c item : flags) {
      item.Candidate__c = candidateId;
    }
    insert as user flags;
  }

  /**
   * Scores the unscored applications of these candidates. Returns a note per candidate that had
   * some. A scoring failure doesn't undo the cards.
   */
  private static Map<Id, String> score(Set<Id> candidateIds) {
    Map<Id, String> notes = new Map<Id, String>();
    if (candidateIds.isEmpty()) {
      return notes;
    }
    Set<Id> scoredCandidates = new Set<Id>();
    for (Job_Applicant__c applicant : [
      SELECT Candidate__c
      FROM Job_Applicant__c
      WHERE Candidate__c IN :candidateIds AND Score__c = NULL
      WITH USER_MODE
    ]) {
      scoredCandidates.add(applicant.Candidate__c);
    }
    if (scoredCandidates.isEmpty()) {
      return notes;
    }
    String note;
    try {
      ScoringService.scoreCandidates(scoredCandidates);
      note = 'Application(s) scored.';
    } catch (Exception ex) {
      note = 'Not scored: ' + ex.getMessage();
    }
    for (Id candidateId : scoredCandidates) {
      notes.put(candidateId, note);
    }
    return notes;
  }

  // =====================================================================================
  // Queries and helpers
  // =====================================================================================

  /**
   * The CV of each candidate: the newest readable file whose title starts with "CV", else the
   * newest readable file, else an unreadable one (so the card says why). Never the photo or an image.
   */
  private static Map<Id, ContentVersion> latestCvs(
    List<Candidate__c> candidates
  ) {
    Map<Id, ContentVersion> result = new Map<Id, ContentVersion>();
    if (candidates.isEmpty()) {
      return result;
    }
    Map<Id, Id> candidateByDocument = candidatesByDocument(candidates);
    Set<Id> documentIds = candidateByDocument.keySet();
    Map<Id, ContentVersion> otherReadable = new Map<Id, ContentVersion>();
    Map<Id, ContentVersion> unreadable = new Map<Id, ContentVersion>();
    // Newest first: the first file seen per candidate and kind wins.
    for (ContentVersion version : [
      SELECT Id, ContentDocumentId, FileExtension, Title
      FROM ContentVersion
      WHERE ContentDocumentId IN :documentIds AND IsLatest = TRUE
      WITH USER_MODE
      ORDER BY CreatedDate DESC
    ]) {
      Id candidateId = candidateByDocument.get(version.ContentDocumentId);
      String extension = version.FileExtension?.toLowerCase();
      Map<Id, ContentVersion> target;
      if (CvTextReader.READABLE_EXTENSIONS.contains(extension)) {
        if (version.Title.toLowerCase().startsWith('cv')) {
          target = result;
        } else {
          target = otherReadable;
        }
      } else if (!Constants.IMAGE_EXTENSIONS.contains(extension)) {
        target = unreadable;
      }
      if (target != null && !target.containsKey(candidateId)) {
        target.put(candidateId, version);
      }
    }
    // Candidates without a "CV..." file: another readable file, else an unreadable one.
    addWhenMissing(result, otherReadable);
    addWhenMissing(result, unreadable);
    return result;
  }

  /**
   * The candidate of each file linked to these candidates, by ContentDocument Id.
   * The profile photos are left out.
   */
  private static Map<Id, Id> candidatesByDocument(
    List<Candidate__c> candidates
  ) {
    Set<Id> photoVersionIds = new Set<Id>();
    Set<Id> candidateIds = new Set<Id>();
    for (Candidate__c candidate : candidates) {
      candidateIds.add(candidate.Id);
      if (candidate.Photo_Version_Id__c != null) {
        photoVersionIds.add(candidate.Photo_Version_Id__c);
      }
    }
    Set<Id> photoDocumentIds = new Set<Id>();
    for (ContentVersion photo : [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id IN :photoVersionIds
      WITH USER_MODE
    ]) {
      photoDocumentIds.add(photo.ContentDocumentId);
    }

    Map<Id, Id> result = new Map<Id, Id>();
    for (ContentDocumentLink link : [
      SELECT ContentDocumentId, LinkedEntityId
      FROM ContentDocumentLink
      WHERE LinkedEntityId IN :candidateIds
      WITH USER_MODE
    ]) {
      if (!photoDocumentIds.contains(link.ContentDocumentId)) {
        result.put(link.ContentDocumentId, link.LinkedEntityId);
      }
    }
    return result;
  }

  /** Copies into target the files of the candidates target doesn't have yet. */
  private static void addWhenMissing(
    Map<Id, ContentVersion> target,
    Map<Id, ContentVersion> source
  ) {
    for (Id candidateId : source.keySet()) {
      if (!target.containsKey(candidateId)) {
        target.put(candidateId, source.get(candidateId));
      }
    }
  }

  /** Existing skill names, so the AI reuses them ("JS" vs "JavaScript") and scoring can match. */
  private static String knownSkills() {
    List<String> names = new List<String>();
    for (Skill__c skill : [
      SELECT Name
      FROM Skill__c
      WITH USER_MODE
      ORDER BY Name
      LIMIT :MAX_KNOWN_SKILLS
    ]) {
      names.add(skill.Name);
    }
    if (names.isEmpty()) {
      return '(none yet)';
    }
    return String.join(names, ', ');
  }

  private static Extraction_Flag__c flag(
    String type,
    String field,
    String detail
  ) {
    return new Extraction_Flag__c(
      Type__c = type,
      Field__c = limitTo(field, 255),
      Detail__c = limitTo(detail, Constants.LONG_TEXT_MAX_LENGTH)
    );
  }

  /** Years outside 0..60 are not believable: dropped (and then reported as Missing). */
  private static Decimal validYears(Decimal years) {
    if (years == null || years < 0 || years > 60) {
      return null;
    }
    return years.setScale(1);
  }

  private static String normalizeEmail(String email) {
    if (email == null) {
      return null;
    }
    String result = email.trim().toLowerCase();
    if (!Constants.isValidEmail(result)) {
      return null;
    }
    return result;
  }

  private static String limitTo(String value, Integer maxLength) {
    if (value == null) {
      return null;
    }
    return value.left(maxLength);
  }
}
