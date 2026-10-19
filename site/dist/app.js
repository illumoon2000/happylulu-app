"use strict";

document.documentElement.classList.add("js");
const english = document.documentElement.lang === "en";

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
  mobileMenu.addEventListener("change", () => setMenuOpen(false));
}

const narrowDocs = window.matchMedia("(max-width: 900px)");
for (const sidebar of document.querySelectorAll("[data-section-nav]")) {
  const toggle = sidebar.querySelector("[data-section-nav-toggle]");
  const links = document.getElementById(toggle.getAttribute("aria-controls"));
  let sectionFocus = null;
  function setSectionOpen(open) {
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
    const remaining = english ? (earlyFriday ? "47m" : "2h 47m") : (earlyFriday ? "47분" : "2시간 47분");
    const leave = earlyFriday ? "15:47" : "17:47";
    for (const element of document.querySelectorAll("[data-countdown]")) element.textContent = remaining;
    for (const element of document.querySelectorAll("[data-leave]")) element.textContent = leave;
    for (const element of document.querySelectorAll("[data-day-label]")) {
      element.textContent = english ? (earlyFriday ? "Lulu" : "Regular") : (earlyFriday ? "룰루데이" : "일반근무");
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
