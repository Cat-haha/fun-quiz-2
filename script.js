// === Variables First ===
let userAnswers = [];
let currentScore = parseInt(localStorage.getItem("currentScore")) || 0;
let playerName = "";
let playerEmail = "";
let currentQuestionIndex = parseInt(localStorage.getItem("currentQuestionIndex")) || 0;
let safeWords = new Set();
let clickAttemptCount = 0;
let attemptCount = 0;
let hasSuggested = false;
let wordList = [];
let currentSuggestion = "";
let fullTextBeforeSuggestion = "";

let lastAutocorrect = {
  corrected: "",
  original: "",
  index: -1,
};

// Use the firebase instance from index.html
const db = firebase.firestore();

currentScore = parseInt(localStorage.getItem("currentScore")) || 0;

function updateUserInfo() {
  const userInfo = document.getElementById("user-info");
  localStorage.setItem("currentScore", currentScore.toString());
  userInfo.textContent = `Logged in as: ${playerName} || Email: ${playerEmail} || Score: ${currentScore}`;
}

// === Auth State Listener ===
firebase.auth().onAuthStateChanged((user) => {
  if (user) {
    playerName = user.displayName || "";
    playerEmail = user.email || "";
    localStorage.setItem("playerName", playerName);
    localStorage.setItem("playerEmail", playerEmail);
    document.getElementById("quiz-container").style.display = "block";
    document.querySelector(".leaderboard-container").style.display = "block";
    document.getElementById("logout-button").style.display = "inline-block";
    document.getElementById("user-info").textContent = `Logged in as: ${playerName} || Email: ${playerEmail}`;
    loadLeaderboard();
    loadQuestion();
  } else {
    document.getElementById("quiz-container").style.display = "none";
    document.querySelector(".leaderboard-container").style.display = "none";
    document.getElementById("logout-button").style.display = "none";
    document.getElementById("user-info").textContent = "";
  }
});

// Remove manual login form logic
// Remove startQuiz and related manual email/name logic
// Only allow endQuiz if user is authenticated
function endQuiz() {
  const user = firebase.auth().currentUser;
  if (!user) {
    alert("You must be signed in with Google to submit your score.");
    return;
  }
  const name = user.displayName;
  const email = user.email;
  const score = parseInt(localStorage.getItem("currentScore"), 10);
  if (localStorage.getItem("scoreSubmitted") === "true") {
    alert("Your score has already been submitted. Current score: " + score);
    return;
  }
  if (!name || !email || isNaN(score)) {
    alert("Missing name, email, or score. Cannot submit.");
    return;
  }
  localStorage.setItem("quizEnded", "true");
  localStorage.setItem("quizStarted", "false");
  db.collection("leaderboard")
    .add({
      name,
      score,
      email,
      answers: userAnswers,
      timestamp: firebase.firestore.FieldValue.serverTimestamp(),
    })
    .then(() => {
      let localLeaderboard = JSON.parse(localStorage.getItem("leaderboard")) || [];
      localLeaderboard.push({ name, score });
      localLeaderboard.sort((a, b) => b.score - a.score);
      localStorage.setItem("leaderboard", JSON.stringify(localLeaderboard));
      localStorage.setItem("scoreSubmitted", "true");
      loadLeaderboard();
      alert(`Your score was: ${score}\nPress any key to continue.`);
      window.location.href = "leaderboard.html";
    })
    .catch((error) => {
      console.error("Error saving score: ", error);
      alert("There was an error submitting your score. Please try again.");
      localStorage.setItem("quizEnded", "false");
      localStorage.setItem("quizStarted", "true");
    });
}

function loadLeaderboard() {
  const tableBody = document.querySelector("#leaderboard-table tbody");
  tableBody.innerHTML = ""; // Clear existing rows

  db.collection("leaderboard")
    .orderBy("score", "desc")
    .limit(10)
    .get()
    .then((querySnapshot) => {
      let firebaseLeaderboard = [];
      querySnapshot.forEach((doc) => {
        const data = doc.data();
        firebaseLeaderboard.push({ name: data.name, score: data.score });
        const row = document.createElement("tr");
        row.innerHTML = `<td>${data.name}</td><td>${data.score}</td>`;
        tableBody.appendChild(row);
      });
      // Save Firebase leaderboard locally
      localStorage.setItem("leaderboard", JSON.stringify(firebaseLeaderboard));
    })
    .catch((error) => {
      console.error("Error loading leaderboard: ", error);
      // fallback to local leaderboard if Firebase fails
      displayLeaderboard();
    });
}


function loadQuestion() {
  attemptCount = 0;
  clickAttemptCount = 0;
  document.getElementById("correct-answer").style.display = "none";
  localStorage.setItem("currentQuestionIndex", currentQuestionIndex);
  localStorage.setItem("currentScore", currentScore.toString());
  const question = questions[currentQuestionIndex];
  const questionElement = document.getElementById("question");
  const questionImage = document.getElementById("question-image");
  const answerInput = document.getElementById("answer");
  const feedback = document.getElementById("feedback");
  const feedbackImage = document.getElementById("feedback-image");
  const nextButton = document.getElementById("next-button");
  const progressElement = document.getElementById("progress");

  questionElement.textContent = question.question;
  answerInput.value = "";
  feedback.textContent = "";
  feedbackImage.src = "";
  feedbackImage.style.display = "none";
  nextButton.style.display = "none";
  progressElement.textContent = `Question ${
    currentQuestionIndex + 1
  } of ${questions.length}`;

  if (question.type === "click") {
    questionImage.src = question.image;
    questionImage.style.display = "block";
    questionImage.onclick = function (event) {
      const userClickedWaldo = checkClickOnWaldo(event, question);
if (userClickedWaldo) {
  showFeedback(true, question);
} else {
  clickAttemptCount++;
  if (clickAttemptCount >= 3) {
    showFeedback(false, question, true); // true = force fail
  } else {
    showFeedback(false, question);
  }
}

    };
  } else {
    questionImage.style.display = question.image ? "block" : "none";
    questionImage.src = question.image || "";
    questionImage.onclick = null;
  }
};  


function checkClickOnWaldo(event, question) {
  const rect = event.target.getBoundingClientRect();
  const x = event.clientX - rect.left;
  const y = event.clientY - rect.top;

  const margin = 20;
  const withinX =
    x > question.waldoX - margin && x < question.waldoX + margin;
  const withinY =
    y > question.waldoY - margin && y < question.waldoY + margin;

  return withinX && withinY;
}

function showFeedback(isCorrect, question) {
  const feedback = document.getElementById("feedback");
  const feedbackImage = document.getElementById("feedback-image");
  const nextButton = document.getElementById("next-button");

if (isCorrect && currentQuestionIndex === 11) {
  feedback.textContent = "✅ Correct! You found Waldo!";
  suggestionBox.style.display = "none";
  let answeredQuestions = JSON.parse(localStorage.getItem("answeredQuestions") || "[]");
  if (answeredQuestions.includes(currentQuestionIndex)) {
    feedback.textContent = "You've already answered this question!";
    return;
  }
if (!answeredQuestions.includes(currentQuestionIndex)) {
  currentScore++;
  updateUserInfo();
  localStorage.setItem("currentScore", currentScore);
  answeredQuestions.push(currentQuestionIndex);
  localStorage.setItem("answeredQuestions", JSON.stringify(answeredQuestions));
  question.answeredCorrectly = true;
}
  if (question.feedbackImage) {
    feedbackImage.src = question.feedbackImage;
    feedbackImage.style.display = "block";
  }
  nextButton.style.display = "inline-block";
  hasSuggested = false;
  return;
}
 else {
    feedback.textContent = "Oops! That's not Waldo.";
    feedbackImage.style.display = "none";
  }

  nextButton.style.display = "inline-block";
}

// Place this after your questions are loaded, near the top of your script:


function submitAnswer() {
  const answerInput = document.getElementById("answer");
  const userAnswer = answerInput.value.trim();
  const question = questions[currentQuestionIndex];
  const feedback = document.getElementById("feedback");
  const feedbackImage = document.getElementById("feedback-image");
  const nextButton = document.getElementById("next-button");
  const correctAnswerDiv = document.getElementById("correct-answer");

  feedback.innerHTML = "";
  feedbackImage.style.display = "none";
  correctAnswerDiv.style.display = "none";

  if (question.type === "click") return;

  // === Lettuce easter egg ===

  const acceptedAnswers = Array.isArray(question.answer)
    ? question.answer.map((a) => a.trim().toLowerCase())
    : [question.answer.trim().toLowerCase()];

  const isCorrect = acceptedAnswers.some(ans => userAnswer.toLowerCase().includes(ans));

  // === Special case for question 0 ===
  if (currentQuestionIndex === 0 && userAnswer.toLowerCase() === "a") {
    feedback.textContent = "HINT: It's not lettuce";
    if (question.hintImage) {
      feedbackImage.src = question.hintImage;
      feedbackImage.style.display = "block";
    }
    return;
  }

  // === Log answer only once ===
  if (!question.loggedAnswer) {
    userAnswers.push({
      questionIndex: currentQuestionIndex,
      questionText: question.question,
      userAnswer: userAnswer,
      acceptedAnswers,
      isCorrect,
      questionType: "text"
    });
    question.loggedAnswer = true;
    localStorage.setItem("userAnswers", JSON.stringify(userAnswers));
  }

  // === Show feedback ===
  if (isCorrect) {
    feedback.textContent = "✅ Correct!";
    suggestionBox.style.display = "none";

    // Prevent infinite score abuse
    let answeredQuestions = JSON.parse(
      localStorage.getItem("answeredQuestions") || "[]"
    );
    if (!answeredQuestions.includes(currentQuestionIndex)) {
      currentScore++;
      updateUserInfo();
      localStorage.setItem("currentScore", currentScore);
      answeredQuestions.push(currentQuestionIndex);
      localStorage.setItem(
        "answeredQuestions",
        JSON.stringify(answeredQuestions)
      );
      question.answeredCorrectly = true;
    }

    if (question.feedbackImage) {
      feedbackImage.src = question.feedbackImage;
      feedbackImage.style.display = "block";
    }

    correctAnswerDiv.textContent = `Correct answer(s): ${acceptedAnswers.join(", ")}`;
    correctAnswerDiv.style.display = "block";

    nextButton.style.display = "inline-block";
    hasSuggested = false;

    // Only transition for #75 and after, and only after correct answer
    if (
      currentQuestionIndex >= colorsSection75Index &&
      document.body.classList.contains("dark-mode")
    ) {
      let transitionImg = transitionImages[currentQuestionIndex] || "";
      if (transitionImg) {
        transitionToLightModeWithImage(transitionImg);
      }
    }
    return;
  } else {
    attemptCount++;
    if (attemptCount >= 2) {
      feedback.textContent = "❌ Incorrect.";
      suggestionBox.style.display = "none";
      correctAnswerDiv.textContent = `Correct answer(s): ${acceptedAnswers.join(", ")}`;
      correctAnswerDiv.style.display = "block";
      nextButton.style.display = "inline-block";

      if (question.feedbackImage) {
        feedbackImage.src = question.feedbackImage;
        feedbackImage.style.display = "block";
      }

      // Only transition for #75 and after, and only after 2 incorrect attempts
      if (
        currentQuestionIndex >= colorsSection75Index &&
        document.body.classList.contains("dark-mode")
      ) {
        let transitionImg = transitionImages[currentQuestionIndex] || "";
        if (transitionImg) {
          transitionToLightModeWithImage(transitionImg);
        }
      }
      return;
    } else {
      feedback.textContent = "❌ Incorrect. Try again!";
    }
  }
}


function logoutPlayer() {
  localStorage.removeItem("quizStarted");
  localStorage.removeItem("quizEnded");
  localStorage.removeItem("currentScore");
  localStorage.removeItem("currentQuestionIndex");
  localStorage.removeItem("scoreSubmitted");
  localStorage.removeItem("playerName");
  localStorage.removeItem("playerEmail");
  localStorage.removeItem("userAnswers");
  localStorage.removeItem("answeredQuestions");
  userAnswers = [];

  currentScore = 0;

  document.getElementById("quiz-container").style.display = "none";
  document.getElementById("start-form").style.display = "block";
  document.getElementById("user-info").textContent = "";
  document.getElementById("player-name").value = "";
  document.getElementById("player-email").value = "";
  window.location.href = "index.html";
}

function restartQuiz() {
    window.location.href = "index.html";
    logoutPlayer();
}

// === Event Listeners ===
document.getElementById("answer").addEventListener("keydown", function (e) {
  const nextButton = document.getElementById("next-button");
  if (e.key === "Enter") {
    // If the next button is visible, trigger its click (handles transition logic)
    if (nextButton.style.display === "inline-block" || nextButton.style.display === "") {
      nextButton.click();
    } else {
      submitAnswer();
    }
  }
});

// Remove duplicate declarations for input, suggestionBox, leaderboard, username
// Only declare these once, near their first use

// === Event Listeners ===
const input = document.getElementById("answer");
const suggestionBox = document.getElementById("suggestion-box");

// === Load Word List ===
fetch("wordsList.txt")
  .then((response) => response.text())
  .then((text) => {
    const words = text.split("\n").map((w) => w.trim().toLowerCase());
    wordList = words;
    safeWords = new Set([...words, ...customSafeWords]);
  });

  function levenshtein(a, b) {
    const matrix = Array.from({ length: a.length + 1 }, () =>
      Array(b.length + 1).fill(0)
    );

    for (let i = 0; i <= a.length; i++) matrix[i][0] = i;
    for (let j = 0; j <= b.length; j++) matrix[0][j] = j;

    for (let i = 1; i <= a.length; i++) {
      for (let j = 1; j <= b.length; j++) {
        matrix[i][j] = Math.min(
          matrix[i - 1][j] + 1,
          matrix[i][j - 1] + 1,
          matrix[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)
        );
      }
    }
    return matrix[a.length][b.length];
  }

  function getClosestWord(word) {
    let minDistance = Infinity;
    let bestMatch = word;
    for (const dictWord of wordList) {
      const dist = levenshtein(word, dictWord);
      if (dist < minDistance) {
        minDistance = dist;
        bestMatch = dictWord;
      }
      if (dist === 1) break;
    }
    return bestMatch;
  }

    input.addEventListener("input", () => {
    const text = input.value;
    const words = text.split(/\s+/);
    const lastWord = words[words.length - 1].toLowerCase();

    if (lastWord === "") {
      suggestionBox.style.display = "none";
      currentSuggestion = "";
      return;
    }

    const match = wordList.find(
      (word) => word.startsWith(lastWord) && word !== lastWord
    );

    if (match) {
      currentSuggestion = match;
      fullTextBeforeSuggestion = words.slice(0, -1).join(" ");
      const rect = input.getBoundingClientRect();
      suggestionBox.textContent = match;
      suggestionBox.style.top = rect.bottom + window.scrollY + "px";
      suggestionBox.style.left = rect.left + window.scrollX + "px";
      suggestionBox.style.display = "block";
    } else {
      suggestionBox.style.display = "none";
      currentSuggestion = "";
    }
  });

    input.addEventListener("keydown", (e) => {
    // Tab for autocomplete/autocorrect
    if (e.key === "Tab" && currentSuggestion) {
      e.preventDefault();
      const text = input.value.trimEnd();
      const words = text.split(/\s+/);
      const lastWord = words[words.length - 1].toLowerCase();

      // Skip autocorrect for safe words
      if (safeWords.has(lastWord)) {
        lastAutocorrect = { corrected: "", original: "", index: -1 };
        return;
      }

      let corrected = "";

      if (customCorrections[lastWord]) {
        corrected = customCorrections[lastWord];
      } else if (!wordList.includes(lastWord)) {
        corrected = getClosestWord(lastWord);
      }

      if (corrected && corrected !== lastWord) {
        lastAutocorrect = {
          corrected,
          original: lastWord,
          index: words.length - 1,
        };
        words[words.length - 1] = corrected;
        input.value = words.join(" ") + " ";
      } else {
        lastAutocorrect = { corrected: "", original: "", index: -1 };
        // If just autocomplete, not autocorrect, fill suggestion
        const newText =
          (fullTextBeforeSuggestion ? fullTextBeforeSuggestion + " " : "") +
          currentSuggestion;
        input.value = newText + " ";
      }
      suggestionBox.style.display = "none";
      currentSuggestion = "";
    }

    // Undo autocorrect on backspace
    if (e.key === "Backspace") {
      const text = input.value.trimEnd();
      const words = text.split(/\s+/);

      if (
        lastAutocorrect.corrected &&
        words.length - 1 === lastAutocorrect.index &&
        words[lastAutocorrect.index] === lastAutocorrect.corrected
      ) {
        words[words.length - 1] = lastAutocorrect.original;
        input.value = words.join(" ") + " ";
        lastAutocorrect = { corrected: "", original: "", index: -1 };
        e.preventDefault(); // avoid removing a letter too
      }
    }
  });

  document.addEventListener("click", () => {
    suggestionBox.style.display = "none";
  });

let leaderboard = JSON.parse(localStorage.getItem('leaderboard')) || [];


function displayLeaderboard() {
  const leaderboardData = JSON.parse(localStorage.getItem("leaderboard")) || [];
  const tableBody = document.querySelector("#leaderboard-table tbody");
  tableBody.innerHTML = ""; // clear old rows

  leaderboardData.forEach(({ name, score }) => {
    const row = document.createElement("tr");
    row.innerHTML = `<td>${name}</td><td>${score}</td>`;
    tableBody.appendChild(row);
  });
}

let username = localStorage.getItem("playerName") || "Anonymous";
leaderboard.push({ name: username, score: currentScore });

document.getElementById("logout-button").addEventListener("click", () => {
  const confirmLogout = window.confirm("Are you sure you want to log out? This will reset ALL your progress.");
  if (confirmLogout) {
    logoutPlayer();
  }
});


document.getElementById("continue-btn").onclick = function () {
  document.getElementById("transition-overlay").style.display = "none";
  document.getElementById("quiz-container").style.display = "";
  currentQuestionIndex++;
  localStorage.setItem("colorsSectionCurrentQuestionIndex", currentQuestionIndex);
  loadQuestion();
};

document.getElementById("end-continue-btn").onclick = function () {
  document.getElementById("end-transition-overlay").style.display = "none";
  document.getElementById("quiz-container").style.display = "";
  // Switch to dark mode
  document.body.classList.add("dark-mode");
  localStorage.setItem("darkMode", "true");
  currentQuestionIndex++;
  localStorage.setItem("colorsSectionCurrentQuestionIndex", currentQuestionIndex);
  loadQuestion();
};

function transitionToLightModeWithImage(newImageSrc, callback) {
  // Switch background to light mode immediately
  document.body.classList.remove("dark-mode");
  localStorage.setItem("darkMode", "false");

  // Fade out the image
  const questionImage = document.getElementById("question-image");
  questionImage.classList.add("transitioning");

  setTimeout(() => {
    questionImage.src = newImageSrc;
    questionImage.onload = () => {
      questionImage.classList.remove("transitioning");
      if (callback) callback();
    };
  }, 500); // Match the CSS transition duration
}

// Google Sign-In function
function signInWithGoogle() {
  const provider = new firebase.auth.GoogleAuthProvider();
  firebase.auth().signInWithPopup(provider)
    .then((result) => {
      // Auth state listener will handle UI
    })
    .catch((error) => {
      alert("Google sign-in failed: " + error.message);
    });
}
window.signInWithGoogle = signInWithGoogle;

document.getElementById("logout-button").addEventListener("click", () => {
  firebase.auth().signOut().then(() => {
    // UI will update via onAuthStateChanged
    localStorage.clear();
    window.location.href = "index.html";
  });
});