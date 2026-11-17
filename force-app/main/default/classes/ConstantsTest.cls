@IsTest
private class ConstantsTest {
  @IsTest
  static void matchLevels() {
    Assert.areEqual(Constants.MATCH_NOT_SCORED, Constants.matchLevel(null));
    Assert.areEqual(
      Constants.MATCH_STRONG,
      Constants.matchLevel(Constants.MATCH_STRONG_SCORE)
    );
    Assert.areEqual(
      Constants.MATCH_PARTIAL,
      Constants.matchLevel(Constants.MATCH_STRONG_SCORE - 1)
    );
    Assert.areEqual(
      Constants.MATCH_PARTIAL,
      Constants.matchLevel(Constants.MATCH_PARTIAL_SCORE)
    );
    Assert.areEqual(
      Constants.MATCH_WEAK,
      Constants.matchLevel(Constants.MATCH_PARTIAL_SCORE - 1)
    );
  }

  @IsTest
  static void validatesEmails() {
    Assert.isTrue(Constants.isValidEmail('sara@demo.com'));
    Assert.isFalse(Constants.isValidEmail(null));
    Assert.isFalse(Constants.isValidEmail('sara@demo'));
    Assert.isFalse(Constants.isValidEmail('sara haddad@demo.com'));
    Assert.isFalse(
      Constants.isValidEmail(
        'a'.repeat(Constants.EMAIL_MAX_LENGTH) + '@demo.com'
      )
    );
  }

  @IsTest
  static void flagTypesMatchThePicklist() {
    Set<String> picklist = new Set<String>();
    for (
      Schema.PicklistEntry entry : Extraction_Flag__c.Type__c.getDescribe()
        .getPicklistValues()
    ) {
      picklist.add(entry.getValue());
    }
    Assert.areEqual(picklist, Constants.FLAG_TYPES);

    Set<String> importance = new Set<String>();
    for (
      Schema.PicklistEntry entry : Job_Skill__c.Importance__c.getDescribe()
        .getPicklistValues()
    ) {
      importance.add(entry.getValue());
    }
    Assert.areEqual(
      new Set<String>{
        Constants.IMPORTANCE_MUST_HAVE,
        Constants.IMPORTANCE_NICE_TO_HAVE
      },
      importance
    );
  }
}
