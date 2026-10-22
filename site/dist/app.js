"use strict";

document.documentElement.classList.add("js");
const english = document.documentElement.lang === "en";

// Keep the explicit Mac download usable without JavaScript; Windows gets its ZIP.
if (/Windows NT/i.test(window.navigator?.userAgent || "")) {
  for (const link of document.querySelectorAll("[data-windows-download]")) {
    link.href = link.dataset.windowsDownload;
    link.textContent = link.dataset.windowsLabel;
  }
}

// Landing anchors stay on the landing page; a linked FAQ opens directly.
function openLinkedAnswer() {
  if (window.location.hash === "#calendar-faq") {
    const answer = document.getElementById("calendar-faq");
    if (answer) answer.open = true;
  }
}
openLinkedAnswer();
window.addEventListener("hashchange", openLinkedAnswer);

const header = document.querySelector(".site-header");
const menuToggle = document.querySelector(".nav-toggle");
const navigation = document.getElementById("site-nav");
function setMenuOpen(open) {
  if (!open && window.matchMedia("(max-width: 650px)").matches && navigation.contains(document.activeElement)) menuToggle.focus();
  header.dataset.menuOpen = String(open);
  menuToggle.setAttribute("aria-expanded", String(open));
  menuToggle.setAttribute("aria-label", english ? (open ? "Close navigation" : "Open navigation") : (open ? "주 메뉴 닫기" : "주 메뉴 열기"));
}
if (header && menuToggle && navigation) {
  menuToggle.hidden = false;
  menuToggle.addEventListener("click", () => setMenuOpen(menuToggle.getAttribute("aria-expanded") !== "true"));
  document.addEventListener("keydown", event => {
    if (event.key === "Escape" && menuToggle.getAttribute("aria-expanded") === "true") {
      setMenuOpen(false);
      menuToggle.focus();
    }
  });
  document.addEventListener("click", event => {
    if (!header.contains(event.target)) setMenuOpen(false);
  });
  navigation.addEventListener("click", event => {
    if (event.target.closest("a")) setMenuOpen(false);
  });
  const mobileMenu = window.matchMedia("(max-width: 650px)");
  mobileMenu.addEventListener("change", () => {
    const previousFocus = document.activeElement;
    setMenuOpen(false);
    if (!mobileMenu.matches && previousFocus === menuToggle) navigation.querySelector("a").focus();
  });
}

const narrowDocs = window.matchMedia("(max-width: 900px)");
for (const sidebar of document.querySelectorAll("[data-section-nav]")) {
  const toggle = sidebar.querySelector("[data-section-nav-toggle]");
  const links = document.getElementById(toggle.getAttribute("aria-controls"));
  let sectionFocus = null;
  function setSectionOpen(open) {
    if (!open && narrowDocs.matches && links.contains(document.activeElement)) toggle.focus();
    sidebar.dataset.navOpen = String(open);
    toggle.setAttribute("aria-expanded", String(open));
  }
  sidebar.dataset.navReady = "true";
  toggle.hidden = false;
  setSectionOpen(!narrowDocs.matches);
  toggle.addEventListener("click", () => setSectionOpen(toggle.getAttribute("aria-expanded") !== "true"));
  document.addEventListener("focusin", event => {
    sectionFocus = sidebar.contains(event.target) ? event.target : null;
  });
  sidebar.addEventListener("keydown", event => {
    if (event.key === "Escape" && narrowDocs.matches && toggle.getAttribute("aria-expanded") === "true") {
      setSectionOpen(false);
      toggle.focus();
    }
  });
  document.addEventListener("click", event => {
    if (!sidebar.contains(event.target)) {
      sectionFocus = null;
      if (narrowDocs.matches) setSectionOpen(false);
    }
  });
  links.addEventListener("click", event => {
    if (narrowDocs.matches && event.target.closest("a")) setSectionOpen(false);
  });
  narrowDocs.addEventListener("change", () => {
    const previousFocus = sectionFocus;
    setSectionOpen(!narrowDocs.matches);
    if (narrowDocs.matches && links.contains(previousFocus)) toggle.focus();
    if (!narrowDocs.matches && previousFocus === toggle) links.querySelector('[aria-current="page"]').focus();
  });
}

// This is a fixed example, not the visitor's attendance or a live app session.
for (const option of document.querySelectorAll('input[name="day-mode"]')) {
  option.addEventListener("change", () => {
    const earlyFriday = option.value === "friday";
    const remaining = english ? (earlyFriday ? "47 min" : "2 hr 47 min") : (earlyFriday ? "47분" : "2시간 47분");
    const leave = earlyFriday ? "15:47" : "17:47";
    for (const element of document.querySelectorAll("[data-countdown]")) element.textContent = remaining;
    for (const element of document.querySelectorAll("[data-leave]")) element.textContent = leave;
    for (const element of document.querySelectorAll("[data-day-label]")) {
      element.textContent = english ? (earlyFriday ? "lulu" : "Regular") : (earlyFriday ? "룰루데이" : "일반근무");
    }
    document.getElementById("demo-progress").style.width = earlyFriday ? "89%" : "69%";
    document.getElementById("demo-note").textContent = english
      ? (earlyFriday ? "Example at 15:00 · last Friday: leave 2 hours earlier, at 15:47" : "Example at 15:00 · arrive 08:47 → leave 17:47")
      : earlyFriday
      ? "15:00 기준 예시 · 마지막 금요일은 2시간 일찍, 15:47 퇴근"
      : "15:00 기준 예시 · 출근 08:47 → 퇴근 17:47";
  });
}

// Platform controls change the visible mobile card without jumping down the page.
const platformSwitch = document.querySelector(".platform-switch");
if (platformSwitch) {
  const buttons = [...platformSwitch.querySelectorAll("button[data-platform]")];
  function selectPlatform(name) {
    for (const button of buttons) button.setAttribute("aria-pressed", String(button.dataset.platform === name));
    for (const card of document.querySelectorAll(".platform-card")) card.dataset.selected = String(card.dataset.platform === name);
  }
  platformSwitch.hidden = false;
  selectPlatform(location.hash === "#windows" ? "windows" : "mac");
  for (const button of buttons) button.addEventListener("click", () => {
    selectPlatform(button.dataset.platform);
    history.replaceState(null, "", "#" + button.dataset.platform);
  });
  window.addEventListener("hashchange", () => selectPlatform(location.hash === "#windows" ? "windows" : "mac"));
}

// Only fixed fictional examples; no clock, attendance storage or network access.
const owlStates = {
  waiting: ["출근 대기", "Waiting", "아직 출근을 기록하지 않은 상태입니다. 또렷하게 뜬 눈으로 기다립니다.", "No arrival recorded yet. Wide-open eyes wait for the day to begin.", "—", "—"],
  regular: ["일반근무", "Regular", "일반근무에 집중하는 표정입니다. 15:00 기준 고정 예시입니다.", "Focused on a regular workday. Fixed example at 15:00.", "09:00", "18:00"],
  luluDay: ["룰루데이", "lulu day", "부리를 열고 기뻐하는 단축근무 표정입니다. 마지막 금요일은 2시간 단축하며, 반차와 중복 적용하지 않습니다.", "An open-beak smile for a shortened workday. The last Friday is 2 hours shorter, never combined with half-day leave.", "09:00", "16:00"],
  morningHalf: ["오전반차", "Morning off", "보는 사람 기준 왼쪽 눈을 감은 윙크입니다. 오전을 쉬고 13:00부터 17:00까지 4시간 근무하는 가상 예시입니다.", "A wink with the viewer’s left eye closed. A fictional four-hour workday from 13:00 to 17:00 after taking the morning off.", "13:00", "17:00"],
  afternoonHalf: ["오후반차", "Afternoon off", "보는 사람 기준 오른쪽 눈을 감은 윙크입니다. 오전에 근무하고 13:00 퇴근 예정인 가상 예시입니다.", "A wink with the viewer’s right eye closed. A fictional morning at work, with departure planned for 13:00.", "09:00", "13:00"],
  readyToLeave: ["예정 시각 경과", "Past planned time", "예정 시각이 지난 뒤의 부리를 다문 미소입니다. 실제 퇴근 기록이 아닙니다. 18:10 기준 고정 예시입니다.", "A closed-beak smile after the planned time. This is not an actual clock-out record. Fixed example at 18:10.", "09:00", "18:00"],
  annualLeave: ["연차·공가", "Annual leave", "연차·공가로 근무하지 않는 날의 행복한 표정입니다. 출근과 퇴근 예정 시각은 없습니다.", "A happy expression for annual or authorized leave. There is no arrival or planned departure.", "—", "—"],
  dayOff: ["오늘 쉬는 날", "Day off", "눈을 반쯤 감고 쉬는 표정입니다. 근무하지 않는 날이며 퇴근 예정 시각은 없습니다.", "Half-closed eyes for a day off. There is no workday or planned departure.", "—", "—"]
};
for (const option of document.querySelectorAll('input[name="owl-state"]')) {
  option.addEventListener("change", () => {
    if (!option.checked) return;
    const state = owlStates[option.value];
    const title = state[english ? 1 : 0];
    for (const image of document.querySelectorAll("[data-owl-image]")) {
      image.setAttribute("src", "/assets/owl-" + option.value + ".png");
      image.setAttribute("alt", title);
    }
    for (const [field, value] of Object.entries({title, description: state[english ? 3 : 2], arrival: state[4], leave: state[5]})) {
      for (const element of document.querySelectorAll("[data-owl-" + field + "]")) element.textContent = value;
    }
  });
}

// Native details remains usable without JavaScript; collapse only on small screens.
for (const toc of document.querySelectorAll("[data-guide-toc]")) {
  const summary = toc.querySelector("summary");
  const narrowGuide = window.matchMedia("(max-width: 720px)");
  function resizeGuide() {
    if (narrowGuide.matches && toc.contains(document.activeElement) && document.activeElement !== summary) summary.focus();
    toc.open = !narrowGuide.matches;
  }
  resizeGuide();
  narrowGuide.addEventListener("change", resizeGuide);
  toc.addEventListener("keydown", event => {
    if (event.key === "Escape" && narrowGuide.matches && toc.open) {
      toc.open = false;
      summary.focus();
    }
  });
  toc.addEventListener("click", event => {
    const link = event.target.closest("a");
    if (!link || !narrowGuide.matches) return;
    const section = document.getElementById(link.hash.slice(1));
    if (section) {
      section.setAttribute("tabindex", "-1");
      section.focus({preventScroll: true});
    }
    toc.open = false;
  });
}
