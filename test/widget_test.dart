import 'package:flutter_test/flutter_test.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:inclass_16/main.dart';

void main() {
  final unescape = HtmlUnescape();

  group('TriviaQuestion Model & Schema Validation', () {
    test('Valid Class A question JSON parses properly', () {
      final json = {
        'category': 'General Knowledge',
        'type': 'multiple',
        'difficulty': 'easy',
        'question': 'How many days are in a leap year?',
        'correct_answer': '366',
        'incorrect_answers': ['365', '364', '367'],
      };

      final q = TriviaQuestion.fromJson(json, unescape);
      expect(q.questionText, 'How many days are in a leap year?');
      expect(q.correctAnswer, '366');
      expect(q.incorrectAnswers.length, 3);
      expect(q.shuffledChoices.length, 4);
      expect(q.shuffledChoices.contains('366'), isTrue);
      expect(q.category, 'General Knowledge');
      expect(q.difficulty, 'easy');
      expect(q.type, 'multiple');
    });

    test('Decodes HTML entities in questions and answers correctly', () {
      final json = {
        'category': 'General Knowledge',
        'type': 'multiple',
        'difficulty': 'easy',
        'question': 'What is &quot;NaCl&quot; commonly known as &amp; used for?',
        'correct_answer': 'Table Salt &#039;Seasoning&#039;',
        'incorrect_answers': ['Sugar &amp; Spice', 'Pepper', 'Flour'],
      };

      final q = TriviaQuestion.fromJson(json, unescape);
      expect(q.questionText, 'What is "NaCl" commonly known as & used for?');
      expect(q.correctAnswer, "Table Salt 'Seasoning'");
      expect(q.incorrectAnswers[0], 'Sugar & Spice');
    });

    test('Rejects non-General Knowledge category', () {
      final json = {
        'category': 'Science: Computers',
        'type': 'multiple',
        'difficulty': 'easy',
        'question': 'What is RAM?',
        'correct_answer': 'Memory',
        'incorrect_answers': ['Disk', 'CPU', 'Screen'],
      };

      expect(
        () => TriviaQuestion.fromJson(json, unescape),
        throwsA(isA<FormatException>()),
      );
    });

    test('Rejects non-easy difficulty', () {
      final json = {
        'category': 'General Knowledge',
        'type': 'multiple',
        'difficulty': 'hard',
        'question': 'Obscure question?',
        'correct_answer': 'A',
        'incorrect_answers': ['B', 'C', 'D'],
      };

      expect(
        () => TriviaQuestion.fromJson(json, unescape),
        throwsA(isA<FormatException>()),
      );
    });

    test('Rejects non-multiple type', () {
      final json = {
        'category': 'General Knowledge',
        'type': 'boolean',
        'difficulty': 'easy',
        'question': 'Is earth round?',
        'correct_answer': 'True',
        'incorrect_answers': ['False'],
      };

      expect(
        () => TriviaQuestion.fromJson(json, unescape),
        throwsA(isA<FormatException>()),
      );
    });

    test('Rejects duplicate choices after decoding', () {
      final json = {
        'category': 'General Knowledge',
        'type': 'multiple',
        'difficulty': 'easy',
        'question': 'Pick one',
        'correct_answer': 'Test',
        'incorrect_answers': ['Test', 'B', 'C'],
      };

      expect(
        () => TriviaQuestion.fromJson(json, unescape),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
