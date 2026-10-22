// Browser supplies native radio/summary keyboard behavior; this checks our event effects.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(__dirname + '/../dist/app.js', 'utf8');
const states = ['waiting', 'regular', 'luluDay', 'morningHalf', 'afternoonHalf', 'readyToLeave', 'annualLeave', 'dayOff'];
for (const lang of ['ko', 'en']) {
  const outputs = Object.fromEntries(['image', 'title', 'description', 'arrival', 'leave'].map(name => [name, {textContent: '', setAttribute(k, v) { this[k] = v; }}]));
  const options = states.map(value => ({value, checked: value === 'regular', listeners: {}, addEventListener(type, fn) {this.listeners[type] = fn;}}));
  const document = {
    documentElement: {lang, classList: {add() {}}},
    querySelector() {return null;},
    getElementById() {return null;},
    querySelectorAll(selector) {
      if (selector === 'input[name="owl-state"]') return options;
      const field = selector.match(/^\[data-owl-(\w+)\]$/);
      return field ? [outputs[field[1]]] : [];
    }
  };
  const context = {document, window: {location: {hash: ''}, addEventListener() {}, matchMedia() {return {matches: false, addEventListener() {}};}}};
  vm.runInNewContext(source, context);
  assert.equal(typeof options[0].listeners.change, 'function', '8-state controls must register change behavior');
  for (const option of options) {
    options.forEach(other => {other.checked = other === option;});
    option.listeners.change();
    assert.equal(outputs.image.src, '/assets/owl-' + option.value + '.png');
    assert.ok(outputs.image.alt.length > 0, 'Owl needs matching accessible state text');
    assert.ok(outputs.title.textContent.length > 0);
    assert.ok(outputs.description.textContent.length > 0);
    assert.equal(outputs.image.alt, outputs.title.textContent);
    if (option.value === 'luluDay') {
      assert.match(outputs.description.textContent, lang === 'ko' ? /단축근무/ : /shortened workday/);
      assert.equal(outputs.leave.textContent, '16:00');
    }
    if (option.value === 'readyToLeave') assert.match(outputs.description.textContent, lang === 'ko' ? /실제 퇴근 기록이 아닙니다/ : /not an actual clock-out record/);
    if (['waiting', 'annualLeave', 'dayOff'].includes(option.value)) assert.equal(outputs.leave.textContent, '—');
    if (option.value === 'morningHalf') {
      assert.equal(outputs.arrival.textContent, '13:00');
      assert.equal(outputs.leave.textContent, '17:00', 'Morning half-day example must span four hours');
    }
    if (option.value === 'afternoonHalf') assert.equal(outputs.leave.textContent, '13:00');
  }
}
console.log('PASS: KO/EN 8-state change events update image, accessible label, meaning and fixed times.');

// Closing navigation must never strand keyboard focus inside hidden links.
{
  const listeners = {};
  const media = {matches: true, addEventListener(type, fn) {this.changed = fn;}};
  const document = {documentElement: {lang: 'ko', classList: {add() {}}}, activeElement: null, addEventListener(type, fn) {listeners[type] = fn;}, querySelectorAll() {return [];}};
  const link = {focus() {document.activeElement = this;}};
  const toggle = {hidden: true, attrs: {'aria-expanded': 'false'}, setAttribute(k, v) {this.attrs[k] = v;}, getAttribute(k) {return this.attrs[k];}, addEventListener(type, fn) {this.clicked = fn;}, focus() {document.activeElement = this;}};
  const navigation = {contains(node) {return node === link;}, addEventListener() {}, querySelector() {return link;}};
  const header = {dataset: {}, contains(node) {return node === link || node === toggle;}};
  document.querySelector = selector => selector === '.site-header' ? header : selector === '.nav-toggle' ? toggle : null;
  document.getElementById = id => id === 'site-nav' ? navigation : null;
  vm.runInNewContext(source, {document, window: {location: {hash: ''}, addEventListener() {}, matchMedia(query) {return query.includes('650') ? media : {matches: false, addEventListener() {}};}}});
  toggle.clicked();
  document.activeElement = link;
  listeners.click({target: {}});
  assert.equal(document.activeElement, toggle, 'Outside close must restore focus before hiding navigation');
  document.activeElement = toggle;
  media.matches = false;
  media.changed();
  assert.equal(document.activeElement, link, 'Desktop resize must move focus away from hidden menu toggle');
}
console.log('PASS: closing mobile navigation and widening to desktop retain visible keyboard focus.');

// Guide collapse returns focus to visible content, preserving every native anchor.
{
  const media = {matches: true, addEventListener(type, fn) {this.changed = fn;}};
  const document = {documentElement: {lang: 'en', classList: {add() {}}}, activeElement: null, querySelector() {return null;}, getElementById(id) {return id === 'install' ? section : null;}};
  const summary = {focus() {document.activeElement = this;}};
  const link = {hash: '#install'};
  const section = {attrs: {}, setAttribute(k, v) {this.attrs[k] = v;}, focus() {document.activeElement = this;}};
  const handlers = {};
  const toc = {open: true, querySelector() {return summary;}, contains(node) {return node === summary || node === link;}, addEventListener(type, fn) {handlers[type] = fn;}};
  document.querySelectorAll = selector => selector === '[data-guide-toc]' ? [toc] : [];
  vm.runInNewContext(source, {document, window: {location: {hash: ''}, addEventListener() {}, matchMedia() {return media;}}});
  assert.equal(toc.open, false, 'Mobile guide starts collapsed');
  toc.open = true;
  document.activeElement = link;
  handlers.click({target: {closest() {return link;}}});
  assert.equal(toc.open, false);
  assert.equal(document.activeElement, section, 'Anchor selection focuses the target section before collapse');
  assert.equal(section.attrs.tabindex, '-1');
  media.matches = false;
  media.changed();
  assert.equal(toc.open, true, 'Desktop guide expands');
  document.activeElement = link;
  media.matches = true;
  media.changed();
  assert.equal(document.activeElement, summary, 'Narrowing restores focus before hiding guide links');
  toc.open = true;
  handlers.keydown({key: 'Escape'});
  assert.equal(toc.open, false);
  assert.equal(document.activeElement, summary);
}
console.log('PASS: guide anchor selection, Escape and responsive collapse keep focus visible.');

// Windows header downloads must change both destination and accessible link text.
for (const lang of ['ko', 'en']) {
  for (const userAgent of ['Mozilla/5.0 (Windows NT 10.0; Win64; x64)', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', 'Mozilla/5.0 (Linux; Android 15)', '']) {
    const link = {
      href: 'https://example.test/mac.dmg',
      textContent: lang === 'ko' ? 'Mac용 다운로드' : 'Download for Mac',
      dataset: {windowsDownload: 'https://example.test/windows.zip', windowsLabel: lang === 'ko' ? 'Windows용 다운로드' : 'Download for Windows'}
    };
    const document = {
      documentElement: {lang, classList: {add() {}}}, querySelector() {return null;}, getElementById() {return null;},
      querySelectorAll(selector) {return selector === '[data-windows-download]' ? [link] : [];}
    };
    vm.runInNewContext(source, {document, window: {navigator: {userAgent}, location: {hash: ''}, addEventListener() {}, matchMedia() {return {matches: false, addEventListener() {}};}}});
    const windows = userAgent.includes('Windows NT');
    assert.equal(link.href, windows ? 'https://example.test/windows.zip' : 'https://example.test/mac.dmg');
    assert.equal(link.textContent, lang === 'ko' ? (windows ? 'Windows용 다운로드' : 'Mac용 다운로드') : (windows ? 'Download for Windows' : 'Download for Mac'));
  }
}
console.log('PASS: KO/EN header downloads select the Windows ZIP and label on Windows, preserving explicit Mac defaults elsewhere.');
