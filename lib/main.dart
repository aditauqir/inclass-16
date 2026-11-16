import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:http/http.dart' as http;

import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint('Firebase initialization failed: $e');
  }
  runApp(const CloudQuizApp());
}

class CloudQuizApp extends StatelessWidget {
  const CloudQuizApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trivia Showdown Cloud',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.white,
        fontFamily: GoogleFonts.outfit().fontFamily,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.black,
          primary: Colors.black,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
        ),
      ),
      home: const TriviaShowdownCloudScreen(),
    );
  }
}

/// Question model representing one validated OpenTDB item.
class TriviaQuestion {
  final String questionText;
  final String correctAnswer;
  final List<String> incorrectAnswers;
  final List<String> shuffledChoices;
  final String category;
  final String difficulty;
  final String type;

  TriviaQuestion({
    required this.questionText,
    required this.correctAnswer,
    required this.incorrectAnswers,
    required this.shuffledChoices,
    required this.category,
    required this.difficulty,
    required this.type,
  });

  factory TriviaQuestion.fromJson(
    Map<String, dynamic> json,
    HtmlUnescape unescape,
  ) {
    final rawCategory = json['category'] as String? ?? '';
    final rawDifficulty = json['difficulty'] as String? ?? '';
    final rawType = json['type'] as String? ?? '';

    if (rawCategory != 'General Knowledge') {
      throw FormatException('Category must be General Knowledge, got "$rawCategory"');
    }
    if (rawDifficulty != 'easy') {
      throw FormatException('Difficulty must be easy, got "$rawDifficulty"');
    }
    if (rawType != 'multiple') {
      throw FormatException('Type must be multiple, got "$rawType"');
    }

    final rawQuestion = json['question'] as String? ?? '';
    final rawCorrect = json['correct_answer'] as String? ?? '';
    final rawIncorrectList = json['incorrect_answers'] as List<dynamic>? ?? [];

    final unescapedQuestion = unescape.convert(rawQuestion).trim();
    final unescapedCorrect = unescape.convert(rawCorrect).trim();

    if (unescapedQuestion.isEmpty) {
      throw const FormatException('Question text is empty after unescaping');
    }
    if (unescapedCorrect.isEmpty) {
      throw const FormatException('Correct answer is empty after unescaping');
    }
    if (rawIncorrectList.length != 3) {
      throw FormatException('Expected exactly 3 incorrect answers, got ${rawIncorrectList.length}');
    }

    final unescapedIncorrect = <String>[];
    for (final inc in rawIncorrectList) {
      final s = unescape.convert(inc.toString()).trim();
      if (s.isEmpty) {
        throw const FormatException('An incorrect answer is empty');
      }
      unescapedIncorrect.add(s);
    }

    final choices = <String>{unescapedCorrect, ...unescapedIncorrect}.toList();
    if (choices.length != 4) {
      throw const FormatException('Duplicate choices detected after unescaping');
    }

    choices.shuffle();

    return TriviaQuestion(
      questionText: unescapedQuestion,
      correctAnswer: unescapedCorrect,
      incorrectAnswers: unescapedIncorrect,
      shuffledChoices: choices,
      category: rawCategory,
      difficulty: rawDifficulty,
      type: rawType,
    );
  }
}

/// App state lifecycle representing quiz & cloud states.
enum AppState {
  signedOut,
  authError,
  loading,
  requestError,
  playing,
  readyToSubmit,
  submitting,
  verifying,
  cloudVerified,
  saveUnknown,
  permissionDenied,
  verificationUnavailable,
}

class TriviaShowdownCloudScreen extends StatefulWidget {
  const TriviaShowdownCloudScreen({super.key});

  @override
  State<TriviaShowdownCloudScreen> createState() => _TriviaShowdownCloudScreenState();
}

class _TriviaShowdownCloudScreenState extends State<TriviaShowdownCloudScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final HtmlUnescape _unescape = HtmlUnescape();

  // Auth fields
  User? _currentUser;
  final TextEditingController _emailController = TextEditingController(text: 'usera@test.com');
  final TextEditingController _passwordController = TextEditingController(text: 'Password123!');
  String? _authErrorMessage;

  // Quiz lifecycle
  AppState _state = AppState.signedOut;
  List<TriviaQuestion> _questions = [];
  int _currentIndex = 0;
  final Map<int, String> _userAnswers = {};
  int _correctCount = 0;
  bool _currentQuestionAnswered = false;
  String? _selectedOptionForCurrent;

  // Cloud identifiers
  String _currentRoundId = '';
  DateTime? _lastFetchTime;
  String? _lastErrorDetail;
  Map<String, dynamic>? _verifiedDocData;
  DateTime? _verifiedServerTime;

  // Testing & Fault Injections
  bool _injectBadJson = false;
  bool _injectNonzeroCode = false;
  bool _injectNineResults = false;
  bool _injectLostAck = false;
  bool _injectUnavailable = false;
  bool _injectResourceExhausted = false;
  String _faultStatusMessage = '';

  // Lookup controller for T07
  final TextEditingController _lookupRoundIdController = TextEditingController();
  String _lookupResult = '';

  @override
  void initState() {
    super.initState();
    _currentUser = _auth.currentUser;
    if (_currentUser != null) {
      _state = AppState.loading;
      _startNewRound();
    } else {
      _state = AppState.signedOut;
    }

    _auth.authStateChanges().listen((user) {
      if (!mounted) return;
      setState(() {
        final previousUser = _currentUser;
        _currentUser = user;
        if (user == null) {
          _state = AppState.signedOut;
          _questions.clear();
          _userAnswers.clear();
        } else if (previousUser == null || previousUser.uid != user.uid) {
          _state = AppState.loading;
          _startNewRound();
        }
      });
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _lookupRoundIdController.dispose();
    super.dispose();
  }

  // --- AUTHENTICATION ---
  Future<void> _signIn() async {
    setState(() {
      _authErrorMessage = null;
      _state = AppState.loading;
    });
    try {
      final cred = await _auth.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      setState(() {
        _currentUser = cred.user;
        _startNewRound();
      });
    } on FirebaseAuthException catch (e) {
      setState(() {
        _state = AppState.authError;
        _authErrorMessage = 'Auth Error (${e.code}): ${e.message}';
      });
    } catch (e) {
      setState(() {
        _state = AppState.authError;
        _authErrorMessage = 'Unexpected error: $e';
      });
    }
  }

  Future<void> _signOut() async {
    if (_state == AppState.submitting || _state == AppState.verifying) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cannot sign out while submission is unresolved',
            style: GoogleFonts.outfit(color: Colors.white),
          ),
          backgroundColor: Colors.black87,
        ),
      );
      return;
    }
    await _auth.signOut();
  }

  // --- QUIZ & ROUND MANAGEMENT ---
  void _startNewRound() {
    if (_currentUser == null) {
      setState(() => _state = AppState.signedOut);
      return;
    }
    // Generate one immutable round ID from Firestore attempts collection
    _currentRoundId = _firestore
        .collection('users')
        .doc(_currentUser!.uid)
        .collection('attempts')
        .doc()
        .id;

    _currentIndex = 0;
    _userAnswers.clear();
    _correctCount = 0;
    _currentQuestionAnswered = false;
    _selectedOptionForCurrent = null;
    _verifiedDocData = null;
    _verifiedServerTime = null;
    _lastErrorDetail = null;

    _fetchQuestions();
  }

  Future<void> _fetchQuestions() async {
    // 5-second rate limiting guard
    if (_lastFetchTime != null) {
      final diff = DateTime.now().difference(_lastFetchTime!);
      if (diff.inSeconds < 5) {
        setState(() {
          _state = AppState.requestError;
          _lastErrorDetail = 'Rate Limit Guard: Please wait ${5 - diff.inSeconds}s before retrying OpenTDB.';
        });
        return;
      }
    }
    _lastFetchTime = DateTime.now();

    setState(() {
      _state = AppState.loading;
      _lastErrorDetail = null;
    });

    try {
      if (_injectBadJson) {
        throw const FormatException('Injected Malformed JSON error');
      }

      final url = Uri.parse(
        'https://opentdb.com/api.php?amount=10&category=9&difficulty=easy&type=multiple',
      );
      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('HTTP status ${response.statusCode}');
      }

      final dynamic data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        throw const FormatException('Expected root JSON object');
      }

      final responseCode = _injectNonzeroCode ? 2 : (data['response_code'] as int? ?? -1);
      if (responseCode != 0) {
        throw Exception('OpenTDB response_code $responseCode: invalid request or no results');
      }

      final results = data['results'] as List<dynamic>? ?? [];
      final effectiveCount = _injectNineResults ? 9 : results.length;
      if (effectiveCount != 10) {
        throw FormatException('Expected exactly 10 questions, got $effectiveCount');
      }

      final parsed = <TriviaQuestion>[];
      for (int i = 0; i < 10; i++) {
        final qJson = results[i] as Map<String, dynamic>;
        parsed.add(TriviaQuestion.fromJson(qJson, _unescape));
      }

      setState(() {
        _questions = parsed;
        _state = AppState.playing;
      });
    } catch (e) {
      setState(() {
        _state = AppState.requestError;
        _lastErrorDetail = e.toString();
      });
    }
  }

  void _selectAnswer(String choice) {
    if (_currentQuestionAnswered) return; // One-answer guard: double-tap prevented

    setState(() {
      _currentQuestionAnswered = true;
      _selectedOptionForCurrent = choice;
      _userAnswers[_currentIndex] = choice;

      if (choice == _questions[_currentIndex].correctAnswer) {
        _correctCount++;
      }
    });
  }

  void _nextQuestion() {
    if (!_currentQuestionAnswered) return;

    if (_currentIndex < _questions.length - 1) {
      setState(() {
        _currentIndex++;
        _currentQuestionAnswered = false;
        _selectedOptionForCurrent = null;
      });
    } else {
      // Completed all 10 questions
      setState(() {
        _state = AppState.readyToSubmit;
      });
    }
  }

  // --- CLOUD COMMIT & VERIFICATION ---
  Future<void> _submitAttempt() async {
    if (_currentUser == null) return;
    if (_state == AppState.submitting || _state == AppState.verifying) return;

    final targetUid = _currentUser!.uid;
    final roundId = _currentRoundId;
    final docRef = _firestore
        .collection('users')
        .doc(targetUid)
        .collection('attempts')
        .doc(roundId);

    setState(() {
      _state = AppState.submitting;
      _lastErrorDetail = null;
    });

    try {
      if (_injectUnavailable) {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'unavailable',
          message: 'Injected repository error: backend service unavailable',
        );
      }
      if (_injectResourceExhausted) {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'resource-exhausted',
          message: 'Injected repository error: quota/resource exhausted',
        );
      }

      // Freeze 6-field payload
      final payload = <String, dynamic>{
        'schemaVersion': 1,
        'variant': 'A',
        'categoryId': 9,
        'questionCount': 10,
        'correctCount': _correctCount,
        'submittedAt': FieldValue.serverTimestamp(),
      };

      // Firestore transaction with read-before-write
      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(docRef);

        if (!snapshot.exists) {
          // Document does not exist: create it
          transaction.set(docRef, payload);
        } else {
          // Reconcile: compare 5 non-timestamp fields
          final existing = snapshot.data();
          if (existing == null) {
            throw Exception('Corrupted existing document');
          }

          final match = existing['schemaVersion'] == payload['schemaVersion'] &&
              existing['variant'] == payload['variant'] &&
              existing['categoryId'] == payload['categoryId'] &&
              existing['questionCount'] == payload['questionCount'] &&
              existing['correctCount'] == payload['correctCount'];

          if (match) {
            debugPrint('Transaction: Attempt $roundId already exists with matching payload. Reusing.');
          } else {
            throw Exception('Collision detected: Round ID $roundId exists with conflicting data');
          }
        }
      });

      // Acknowledgement loss fault injection
      if (_injectLostAck) {
        setState(() {
          _state = AppState.saveUnknown;
          _faultStatusMessage = 'Injected Fault: Acknowledgement lost. Transaction committed on cloud, but ack suppressed.';
        });
        return;
      }

      // Post-commit server-only read
      await _verifyOnServer(docRef, targetUid, roundId);
    } on FirebaseException catch (e) {
      setState(() {
        if (e.code == 'permission-denied') {
          _state = AppState.permissionDenied;
        } else {
          _state = AppState.readyToSubmit;
        }
        _lastErrorDetail = 'Firestore [${e.code}]: ${e.message}';
      });
    } catch (e) {
      setState(() {
        _state = AppState.readyToSubmit;
        _lastErrorDetail = e.toString();
      });
    }
  }

  Future<void> _verifyOnServer(
    DocumentReference<Map<String, dynamic>> docRef,
    String expectedUid,
    String expectedRoundId,
  ) async {
    setState(() {
      _state = AppState.verifying;
    });

    try {
      final snapshot = await docRef.get(const GetOptions(source: Source.server));

      if (!snapshot.exists) {
        throw Exception('Server read returned no document at path');
      }

      if (snapshot.metadata.hasPendingWrites) {
        throw Exception('Verification read reported pending client writes; not server-authoritative');
      }

      final data = snapshot.data();
      if (data == null) {
        throw Exception('Server document is empty');
      }

      // Validate contract fields
      if (data['schemaVersion'] != 1 ||
          data['variant'] != 'A' ||
          data['categoryId'] != 9 ||
          data['questionCount'] != 10 ||
          data['correctCount'] != _correctCount) {
        throw Exception('Server document payload failed validation: $data');
      }

      final ts = data['submittedAt'];
      if (ts is! Timestamp) {
        throw Exception('Server submittedAt is not a resolved Timestamp: $ts');
      }

      // Stale completion guard: ensure user and round didn't change
      if (_currentUser?.uid != expectedUid || _currentRoundId != expectedRoundId) {
        debugPrint('Discarded stale verification completion for old user/round');
        return;
      }

      setState(() {
        _verifiedDocData = data;
        _verifiedServerTime = ts.toDate();
        _state = AppState.cloudVerified;
      });
    } catch (e) {
      setState(() {
        _state = AppState.verificationUnavailable;
        _lastErrorDetail = 'Verification Unavailable: $e';
      });
    }
  }

  // --- FAULT RECOVERY FROM saveUnknown ---
  Future<void> _reconcileFromSaveUnknown() async {
    if (_currentUser == null) return;
    final docRef = _firestore
        .collection('users')
        .doc(_currentUser!.uid)
        .collection('attempts')
        .doc(_currentRoundId);

    await _verifyOnServer(docRef, _currentUser!.uid, _currentRoundId);
  }

  // --- DIRECT SERVER LOOKUP (FOR T07 RESTORE TEST) ---
  Future<void> _lookupAttemptById(String roundId) async {
    if (_currentUser == null || roundId.trim().isEmpty) return;
    setState(() {
      _lookupResult = 'Fetching from server...';
    });

    try {
      final docRef = _firestore
          .collection('users')
          .doc(_currentUser!.uid)
          .collection('attempts')
          .doc(roundId.trim());

      final snapshot = await docRef.get(const GetOptions(source: Source.server));
      if (!snapshot.exists) {
        setState(() {
          _lookupResult = 'Document not found on server.';
        });
        return;
      }

      final data = snapshot.data()!;
      final ts = (data['submittedAt'] as Timestamp?)?.toDate();
      setState(() {
        _lookupResult = 'FOUND on server:\n'
            'Path: users/${_currentUser!.uid}/attempts/${roundId.trim()}\n'
            'schemaVersion: ${data['schemaVersion']}\n'
            'variant: ${data['variant']}\n'
            'categoryId: ${data['categoryId']}\n'
            'questionCount: ${data['questionCount']}\n'
            'correctCount: ${data['correctCount']}\n'
            'submittedAt: $ts\n'
            'hasPendingWrites: ${snapshot.metadata.hasPendingWrites}';
      });
    } catch (e) {
      setState(() {
        _lookupResult = 'Lookup failed: $e';
      });
    }
  }

  // --- RULE TEST RUNNERS (T10, T11) ---
  Future<void> _runRuleTest(String testType) async {
    if (_currentUser == null) return;
    setState(() => _faultStatusMessage = 'Running rule test $testType...');

    try {
      if (testType == 'T10_userB_write_userA') {
        final foreignRef = _firestore
            .collection('users')
            .doc('uUbFtAlmQAfiGWFlfwUMdp5pxmo1') // User A UID
            .collection('attempts')
            .doc('unauthorized-round');
        await foreignRef.set({
          'schemaVersion': 1,
          'variant': 'A',
          'categoryId': 9,
          'questionCount': 10,
          'correctCount': 10,
          'submittedAt': FieldValue.serverTimestamp(),
        });
        setState(() => _faultStatusMessage = 'FAILURE: Foreign write was allowed!');
      } else if (testType == 'T10_userB_read_userA') {
        final foreignRef = _firestore
            .collection('users')
            .doc('uUbFtAlmQAfiGWFlfwUMdp5pxmo1')
            .collection('attempts')
            .doc('unauthorized-round');
        await foreignRef.get(const GetOptions(source: Source.server));
        setState(() => _faultStatusMessage = 'FAILURE: Foreign read was allowed!');
      } else if (testType == 'T11_score_11') {
        final ref = _firestore
            .collection('users')
            .doc(_currentUser!.uid)
            .collection('attempts')
            .doc('test-invalid-score');
        await ref.set({
          'schemaVersion': 1,
          'variant': 'A',
          'categoryId': 9,
          'questionCount': 10,
          'correctCount': 11, // VIOLATION
          'submittedAt': FieldValue.serverTimestamp(),
        });
        setState(() => _faultStatusMessage = 'FAILURE: Score 11 was allowed!');
      } else if (testType == 'T11_extra_field') {
        final ref = _firestore
            .collection('users')
            .doc(_currentUser!.uid)
            .collection('attempts')
            .doc('test-extra-field');
        await ref.set({
          'schemaVersion': 1,
          'variant': 'A',
          'categoryId': 9,
          'questionCount': 10,
          'correctCount': 5,
          'submittedAt': FieldValue.serverTimestamp(),
          'hackedField': true, // VIOLATION
        });
        setState(() => _faultStatusMessage = 'FAILURE: Extra field was allowed!');
      } else if (testType == 'T11_update_forbidden') {
        final ref = _firestore
            .collection('users')
            .doc(_currentUser!.uid)
            .collection('attempts')
            .doc(_currentRoundId);
        await ref.update({'correctCount': 10}); // VIOLATION
        setState(() => _faultStatusMessage = 'FAILURE: Update was allowed!');
      }
    } on FirebaseException catch (e) {
      setState(() {
        _faultStatusMessage = 'DENIED as expected by rules! (${e.code}): ${e.message}';
      });
    } catch (e) {
      setState(() {
        _faultStatusMessage = 'Error: $e';
      });
    }
  }

  // --- STYLING HELPERS (FROM INCLASS-15) ---
  TextStyle _labelStyle({Color? color}) => GoogleFonts.outfit(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.4,
        color: color ?? Colors.grey.shade600,
      );

  Widget _scoreChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'SCORE $_correctCount',
        style: GoogleFonts.outfit(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
          color: Colors.white,
        ),
      ),
    );
  }

  void _showTestSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'TEST & FAULT INJECTION SUITE',
                      style: _labelStyle(color: Colors.black),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilterChip(
                          label: Text('T03: Bad JSON', style: GoogleFonts.outfit(fontSize: 12)),
                          selected: _injectBadJson,
                          onSelected: (v) {
                            setState(() => _injectBadJson = v);
                            setSheetState(() {});
                          },
                        ),
                        FilterChip(
                          label: Text('T03: Nonzero Code', style: GoogleFonts.outfit(fontSize: 12)),
                          selected: _injectNonzeroCode,
                          onSelected: (v) {
                            setState(() => _injectNonzeroCode = v);
                            setSheetState(() {});
                          },
                        ),
                        FilterChip(
                          label: Text('T03: 9 Results', style: GoogleFonts.outfit(fontSize: 12)),
                          selected: _injectNineResults,
                          onSelected: (v) {
                            setState(() => _injectNineResults = v);
                            setSheetState(() {});
                          },
                        ),
                        FilterChip(
                          label: Text('T09: Lost Ack', style: GoogleFonts.outfit(fontSize: 12)),
                          selected: _injectLostAck,
                          onSelected: (v) {
                            setState(() => _injectLostAck = v);
                            setSheetState(() {});
                          },
                        ),
                        FilterChip(
                          label: Text('T12: Unavailable', style: GoogleFonts.outfit(fontSize: 12)),
                          selected: _injectUnavailable,
                          onSelected: (v) {
                            setState(() => _injectUnavailable = v);
                            setSheetState(() {});
                          },
                        ),
                        FilterChip(
                          label: Text('T12: Quota Exhausted', style: GoogleFonts.outfit(fontSize: 12)),
                          selected: _injectResourceExhausted,
                          onSelected: (v) {
                            setState(() => _injectResourceExhausted = v);
                            setSheetState(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'SECURITY RULES TESTS',
                      style: _labelStyle(color: Colors.black),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () async {
                            await _runRuleTest('T10_userB_write_userA');
                            setSheetState(() {});
                          },
                          child: Text('T10: Write User A', style: GoogleFonts.outfit(fontSize: 11)),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            await _runRuleTest('T10_userB_read_userA');
                            setSheetState(() {});
                          },
                          child: Text('T10: Read User A', style: GoogleFonts.outfit(fontSize: 11)),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            await _runRuleTest('T11_score_11');
                            setSheetState(() {});
                          },
                          child: Text('T11: Score 11', style: GoogleFonts.outfit(fontSize: 11)),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            await _runRuleTest('T11_extra_field');
                            setSheetState(() {});
                          },
                          child: Text('T11: Extra Field', style: GoogleFonts.outfit(fontSize: 11)),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            await _runRuleTest('T11_update_forbidden');
                            setSheetState(() {});
                          },
                          child: Text('T11: Update Attempt', style: GoogleFonts.outfit(fontSize: 11)),
                        ),
                      ],
                    ),
                    if (_faultStatusMessage.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _faultStatusMessage,
                          style: GoogleFonts.outfit(fontSize: 12, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'T07 DOCUMENT LOOKUP VIA SERVER READ',
                      style: _labelStyle(color: Colors.black),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _lookupRoundIdController,
                            style: GoogleFonts.outfit(fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'Enter completed round ID',
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black,
                            foregroundColor: Colors.white,
                            shape: const StadiumBorder(),
                          ),
                          onPressed: () async {
                            await _lookupAttemptById(_lookupRoundIdController.text);
                            setSheetState(() {});
                          },
                          child: Text('Lookup', style: GoogleFonts.outfit(fontSize: 12)),
                        ),
                      ],
                    ),
                    if (_lookupResult.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _lookupResult,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          'API-to-Cloud Showdown',
          style: GoogleFonts.outfit(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.black,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.science_outlined, color: Colors.black87),
            tooltip: 'Testing & Diagnostics',
            onPressed: _showTestSheet,
          ),
          if (_currentUser != null)
            IconButton(
              icon: const Icon(Icons.logout_rounded, color: Colors.black87),
              tooltip: 'Sign Out',
              onPressed: _signOut,
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0),
          child: _buildCurrentBody(),
        ),
      ),
    );
  }

  Widget _buildCurrentBody() {
    if (_state == AppState.signedOut || _state == AppState.authError) {
      return _buildAuthScreen();
    }
    if (_state == AppState.loading) {
      return _buildLoading();
    }
    if (_state == AppState.requestError) {
      return _buildRequestError();
    }
    if (_state == AppState.playing) {
      return _buildPlayingRound();
    }
    return _buildResultsAndReview();
  }

  // --- SIGN IN SCREEN ---
  Widget _buildAuthScreen() {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.lock_person_outlined, size: 30, color: Colors.black87),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Sign In to Play',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Cloud attempts are strictly stored under your Firebase UID.',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              style: GoogleFonts.outfit(fontSize: 14),
              decoration: InputDecoration(
                labelText: 'Email Address',
                labelStyle: GoogleFonts.outfit(color: Colors.grey.shade600),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: Colors.black, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _passwordController,
              obscureText: true,
              style: GoogleFonts.outfit(fontSize: 14),
              decoration: InputDecoration(
                labelText: 'Password',
                labelStyle: GoogleFonts.outfit(color: Colors.grey.shade600),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: Colors.black, width: 1.5),
                ),
              ),
            ),
            if (_authErrorMessage != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _authErrorMessage!,
                        style: GoogleFonts.outfit(color: Colors.red.shade700, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              height: 52,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: const StadiumBorder(),
                ),
                onPressed: _signIn,
                child: Text(
                  'Sign In',
                  style: GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- LOADING SCREEN ---
  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            height: 32,
            width: 32,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black),
          ),
          const SizedBox(height: 18),
          Text(
            'Fetching 10 live questions...',
            style: GoogleFonts.outfit(fontSize: 14, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  // --- REQUEST ERROR SCREEN ---
  Widget _buildRequestError() {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          border: Border.all(color: Colors.red.shade200),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, color: Colors.red.shade400, size: 36),
            const SizedBox(height: 14),
            Text(
              _lastErrorDetail ?? 'Request error fetching trivia questions',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(fontSize: 14, color: Colors.red.shade700),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
              ),
              onPressed: _fetchQuestions,
              child: Text(
                'Try Again (5s Rate Limited)',
                style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- PLAYING SCREEN ---
  Widget _buildPlayingRound() {
    final question = _questions[_currentIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              'QUESTION ${_currentIndex + 1} OF ${_questions.length}',
              style: _labelStyle(),
            ),
            const Spacer(),
            _scoreChip(),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: (_currentIndex + 1) / _questions.length,
            minHeight: 4,
            backgroundColor: Colors.grey.shade200,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: 20),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Text(
                    question.questionText,
                    style: GoogleFonts.outfit(
                      fontSize: 22,
                      fontWeight: FontWeight.w500,
                      height: 1.35,
                      letterSpacing: -0.2,
                      color: Colors.black87,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                ...question.shuffledChoices.asMap().entries.map(
                      (entry) => _buildAnswerOption(entry.value, entry.key),
                    ),
              ],
            ),
          ),
        ),
        if (_currentQuestionAnswered) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: const StadiumBorder(),
              ),
              onPressed: _nextQuestion,
              child: Text(
                _currentIndex < _questions.length - 1 ? 'Next Question →' : 'View Final Score',
                style: GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildAnswerOption(String option, int index) {
    final isCorrect = option == _questions[_currentIndex].correctAnswer;
    final isSelected = option == _selectedOptionForCurrent;

    var background = Colors.white;
    var border = Colors.grey.shade300;
    var foreground = Colors.black87;
    var badgeBackground = Colors.grey.shade100;
    IconData? trailingIcon;
    Color? trailingColor;

    if (_currentQuestionAnswered && isCorrect) {
      background = Colors.green.shade50;
      border = Colors.green.shade600;
      foreground = Colors.green.shade900;
      badgeBackground = Colors.green.shade100;
      trailingIcon = Icons.check_rounded;
      trailingColor = Colors.green.shade700;
    } else if (_currentQuestionAnswered && isSelected) {
      background = Colors.red.shade50;
      border = Colors.red.shade400;
      foreground = Colors.red.shade900;
      badgeBackground = Colors.red.shade100;
      trailingIcon = Icons.close_rounded;
      trailingColor = Colors.red.shade600;
    } else if (_currentQuestionAnswered) {
      foreground = Colors.grey.shade500;
      border = Colors.grey.shade200;
      badgeBackground = Colors.grey.shade50;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          elevation: 0,
          minimumSize: const Size(double.infinity, 58),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: border, width: 1.2),
          ),
        ),
        onPressed: _currentQuestionAnswered ? null : () => _selectAnswer(option),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: badgeBackground,
                shape: BoxShape.circle,
              ),
              child: Text(
                String.fromCharCode(65 + index),
                style: GoogleFonts.outfit(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: foreground,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                option,
                style: GoogleFonts.outfit(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: foreground,
                ),
              ),
            ),
            if (trailingIcon != null) ...[
              const SizedBox(width: 8),
              Icon(trailingIcon, size: 20, color: trailingColor),
            ],
          ],
        ),
      ),
    );
  }

  // --- RESULTS & REVIEW SCREEN ---
  Widget _buildResultsAndReview() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Center(
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.emoji_events_outlined,
                size: 30,
                color: Colors.black87,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Showdown Complete!',
            textAlign: TextAlign.center,
            style: GoogleFonts.outfit(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Signed in as ${_currentUser?.email ?? 'Unknown User'}',
            textAlign: TextAlign.center,
            style: GoogleFonts.outfit(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 20),
          Center(
            child: Column(
              children: [
                Text('FINAL SCORE', style: _labelStyle()),
                const SizedBox(height: 6),
                Text(
                  '$_correctCount / ${_questions.length}',
                  style: GoogleFonts.outfit(
                    fontSize: 44,
                    fontWeight: FontWeight.w600,
                    height: 1,
                    letterSpacing: -1,
                    color: Colors.black,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Round ID metadata card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ROUND ATTEMPT METADATA',
                  style: _labelStyle(color: Colors.black54),
                ),
                const SizedBox(height: 6),
                Text(
                  'Round ID: $_currentRoundId',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.black87),
                ),
                Text(
                  'Path: users/${_currentUser?.uid}/attempts/$_currentRoundId',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
          if (_state == AppState.cloudVerified && _verifiedDocData != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.green.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.verified_rounded, color: Colors.green.shade700, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Cloud Verified (Source.server)',
                        style: GoogleFonts.outfit(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: Colors.green.shade900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('schemaVersion: ${_verifiedDocData!['schemaVersion']}', style: GoogleFonts.outfit(fontSize: 12)),
                  Text('variant: ${_verifiedDocData!['variant']}', style: GoogleFonts.outfit(fontSize: 12)),
                  Text('categoryId: ${_verifiedDocData!['categoryId']}', style: GoogleFonts.outfit(fontSize: 12)),
                  Text('questionCount: ${_verifiedDocData!['questionCount']}', style: GoogleFonts.outfit(fontSize: 12)),
                  Text('correctCount: ${_verifiedDocData!['correctCount']}', style: GoogleFonts.outfit(fontSize: 12)),
                  Text('submittedAt: $_verifiedServerTime', style: GoogleFonts.outfit(fontSize: 12)),
                ],
              ),
            ),
          ],
          if (_state == AppState.saveUnknown) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.amber.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.help_outline_rounded, color: Colors.amber.shade800, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Lost Acknowledgement (saveUnknown)',
                        style: GoogleFonts.outfit(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: Colors.amber.shade900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Transaction committed on backend, but client UI suppressed completion. Recover by reading the exact same round ID from the server.',
                    style: GoogleFonts.outfit(fontSize: 12, color: Colors.black87),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      shape: const StadiumBorder(),
                    ),
                    onPressed: _reconcileFromSaveUnknown,
                    child: Text('Reconcile via Server Read', style: GoogleFonts.outfit(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ],
          if (_lastErrorDetail != null) ...[
            const SizedBox(height: 8),
            Text(
              _lastErrorDetail!,
              style: GoogleFonts.outfit(color: Colors.red.shade700, fontSize: 12),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                    label: Text(
                      _state == AppState.submitting
                          ? 'Submitting...'
                          : _state == AppState.verifying
                              ? 'Verifying...'
                              : _state == AppState.cloudVerified
                                  ? 'Synced to Cloud'
                                  : 'Submit to Cloud',
                      style: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: const StadiumBorder(),
                    ),
                    onPressed: (_state == AppState.submitting ||
                            _state == AppState.verifying ||
                            _state == AppState.cloudVerified)
                        ? null
                        : _submitAttempt,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(
                      'Play Again',
                      style: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.black,
                      side: BorderSide(color: Colors.grey.shade300),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: (_state == AppState.submitting || _state == AppState.verifying)
                        ? null
                        : _startNewRound,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'QUESTION REVIEW',
            style: _labelStyle(),
          ),
          const SizedBox(height: 10),
          ...List.generate(_questions.length, (i) {
            final q = _questions[i];
            final selected = _userAnswers[i] ?? 'No answer';
            final isCorrect = selected == q.correctAnswer;

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isCorrect ? Colors.green.shade50.withValues(alpha: 0.5) : Colors.red.shade50.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isCorrect ? Colors.green.shade200 : Colors.red.shade200,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isCorrect ? Colors.green.shade100 : Colors.red.shade100,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Q${i + 1}',
                          style: GoogleFonts.outfit(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: isCorrect ? Colors.green.shade900 : Colors.red.shade900,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          q.questionText,
                          style: GoogleFonts.outfit(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Your answer: $selected',
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: isCorrect ? Colors.green.shade800 : Colors.red.shade800,
                    ),
                  ),
                  if (!isCorrect)
                    Text(
                      'Correct answer: ${q.correctAnswer}',
                      style: GoogleFonts.outfit(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Colors.green.shade800,
                      ),
                    ),
                ],
              ),
            );
          }),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
