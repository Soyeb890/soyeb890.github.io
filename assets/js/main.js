// Raqeeb Garments Workshop V2 — homepage behavior
// Minimal vanilla JS. No frameworks, no build step.

// Footer year
(function () {
  var y = document.getElementById('y');
  if (y) y.textContent = new Date().getFullYear();
})();

// Mobile navigation drawer — animates open/closed via a CSS max-height
// transition, so `hidden` is only applied once the close transition ends
// (keeps it out of the tab order without cutting the animation short).
(function () {
  var toggle = document.getElementById('navToggle');
  var drawer = document.getElementById('drawer');
  if (!toggle || !drawer) return;

  var closeTimer = null;

  function openDrawer() {
    clearTimeout(closeTimer);
    drawer.hidden = false;
    requestAnimationFrame(function () {
      drawer.classList.add('open');
    });
    toggle.setAttribute('aria-expanded', 'true');
    toggle.setAttribute('aria-label', 'Close menu');
  }

  function closeDrawer(returnFocus) {
    drawer.classList.remove('open');
    toggle.setAttribute('aria-expanded', 'false');
    toggle.setAttribute('aria-label', 'Open menu');
    clearTimeout(closeTimer);
    closeTimer = setTimeout(function () {
      drawer.hidden = true;
    }, 350);
    if (returnFocus) toggle.focus();
  }

  toggle.addEventListener('click', function () {
    if (drawer.classList.contains('open')) {
      closeDrawer(false);
    } else {
      openDrawer();
    }
  });

  // closest('a') rather than checking e.target.tagName directly: the drawer
  // links contain no nested elements today, but tagName-only checks break
  // the moment a tap lands on an icon/span inside an <a>, so this is the
  // robust form regardless.
  drawer.addEventListener('click', function (e) {
    if (e.target.closest('a')) closeDrawer(false);
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && drawer.classList.contains('open')) {
      closeDrawer(true);
    }
  });
})();

// Scroll-spy: highlight the nav link for whichever main section is
// currently in view, in both the desktop menu and the mobile drawer.
(function () {
  var sectionIds = ['industries', 'process', 'private-label', 'faq', 'contact'];
  var sections = sectionIds
    .map(function (id) { return document.getElementById(id); })
    .filter(Boolean);
  if (!sections.length || !('IntersectionObserver' in window)) return;

  var links = document.querySelectorAll('.menulinks a, .drawer .links a');

  function setActive(id) {
    links.forEach(function (link) {
      var isMatch = link.getAttribute('href') === '#' + id;
      link.classList.toggle('active', isMatch);
    });
  }

  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) setActive(entry.target.id);
    });
  }, { rootMargin: '-45% 0px -50% 0px', threshold: 0 });

  sections.forEach(function (section) { io.observe(section); });
})();

// Sticky header: subtle shadow once the page has scrolled
(function () {
  var header = document.getElementById('siteHeader');
  if (!header) return;
  var onScroll = function () {
    header.classList.toggle('scrolled', window.scrollY > 8);
  };
  document.addEventListener('scroll', onScroll, { passive: true });
  onScroll();
})();

// Google Map: don't trap scroll gestures until the visitor taps/clicks it
// once. Listens on the map's own wrapper specifically — not the whole
// contact card — so tapping a phone number or the "Open in Google Maps"
// button alongside it doesn't also arm the map's pointer-events.
(function () {
  var map = document.querySelector('iframe.map');
  var mapWrap = map && map.closest('.map-wrap');
  if (!map || !mapWrap) return;
  mapWrap.addEventListener('click', function () {
    map.classList.add('is-active');
  }, { once: true });
})();

// Quote form: buttons with data-prefill drop a starting message into the
// textarea so each entry point leads to a more useful enquiry, without
// changing where the form submits.
(function () {
  var message = document.getElementById('msg');
  if (!message) return;

  var prefillButtons = document.querySelectorAll('[data-prefill]');
  for (var i = 0; i < prefillButtons.length; i++) {
    prefillButtons[i].addEventListener('click', function (e) {
      if (!message.value.trim()) {
        message.value = e.currentTarget.getAttribute('data-prefill');
      }
    });
  }
})();

// WhatsApp FAB: step back (and drop out of the tab order) while another
// WhatsApp action is already reachable on-screen, or while the homepage
// Contact section itself is meaningfully in view (the visitor is already
// inside the conversion area at that point, so a floating duplicate is
// redundant and, on short viewports, can sit over the form fields).
// Watches actual destination (any wa.me link) rather than a specific class —
// `.btn-whatsapp` alone missed hero/product-page WhatsApp CTAs, which are
// styled `.btn-on-dark`, letting the FAB stay visible and overlap them.
(function () {
  var fab = document.querySelector('.whatsapp-fab');
  if (!fab || !('IntersectionObserver' in window)) return;

  var links = Array.prototype.filter.call(
    document.querySelectorAll('a[href*="wa.me"]'),
    function (el) { return el !== fab; }
  );
  var contactSection = document.getElementById('contact');

  var linksVisible = 0;
  var contactVisible = false;

  function updateFab() {
    fab.classList.toggle('is-muted', linksVisible > 0 || contactVisible);
  }

  if (links.length) {
    var linkIo = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        linksVisible += entry.isIntersecting ? 1 : -1;
      });
      linksVisible = Math.max(0, linksVisible);
      updateFab();
    }, { threshold: 0.6 });
    links.forEach(function (el) { linkIo.observe(el); });
  }

  if (contactSection) {
    var contactIo = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        contactVisible = entry.isIntersecting;
      });
      updateFab();
    }, { threshold: 0.15 });
    contactIo.observe(contactSection);
  }
})();

// Product-context quote flow: a product page's "Get a Quote" link carries
// ?product=Name into the homepage URL; once here, that populates the
// visible Product / Requirement field so the buyer doesn't have to retype
// what they already told us, without overwriting anything they've typed.
(function () {
  var params = new URLSearchParams(window.location.search);
  var product = params.get('product');
  if (!product) return;
  var field = document.getElementById('product');
  if (field && !field.value.trim()) field.value = product;
})();

// Scroll-triggered reveal: fade/slide in .reveal, .stagger and .reveal-row
// blocks as they enter the viewport. Respects prefers-reduced-motion (handled
// in CSS by making the initial state already visible there's no need to
// branch here, but we still skip the observer entirely to avoid needless work).
// .reveal-row (the industries rows) is included here rather than run through
// .stagger so each row animates individually as it crosses the viewport
// while scrolling, instead of the whole list firing as one batch.
// Wrapped in try/catch as a last-resort safety net: CSS only hides
// .reveal/.stagger/.reveal-row content once <html> carries .js-reveal (added
// by the inline script in <head>), on the assumption that this block will
// run and eventually mark everything .is-visible. If anything here throws
// before that happens, the catch block reveals everything immediately
// instead of leaving content permanently hidden. See also the `onerror`
// fallback on the main.js <script> tag itself, which handles the case where
// this whole file fails to load in the first place.
(function () {
  try {
    var reduceMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var targets = document.querySelectorAll('.reveal, .stagger, .reveal-row');
    if (!targets.length) return;

    if (reduceMotion || !('IntersectionObserver' in window)) {
      targets.forEach(function (el) { el.classList.add('is-visible'); });
      return;
    }

    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -8% 0px' });

    targets.forEach(function (el) { io.observe(el); });
  } catch (e) {
    document.querySelectorAll('.reveal, .stagger, .reveal-row').forEach(function (el) {
      el.classList.add('is-visible');
    });
  }
})();

// Sequential activation for the capability and process flows: as each stage
// enters the viewport, it — and every stage before it — is marked active,
// and the connecting line's custom property is updated so it visibly grows
// to that point. Distinct from the reveal system above: this tracks
// left-to-right/top-to-bottom production progress, not just visibility.
(function () {
  var reduceMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  function wireSequentialFlow(listSelector, itemSelector, cssVar) {
    var list = document.querySelector(listSelector);
    if (!list) return;
    var items = Array.prototype.slice.call(list.querySelectorAll(itemSelector));
    if (!items.length) return;

    function activateUpTo(index) {
      items.forEach(function (item, i) {
        if (i <= index) item.classList.add('is-active');
      });
      list.style.setProperty(cssVar, (index + 1) / items.length);
    }

    if (reduceMotion || !('IntersectionObserver' in window)) {
      activateUpTo(items.length - 1);
      return;
    }

    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) activateUpTo(items.indexOf(entry.target));
      });
    }, { threshold: 0.5, rootMargin: '0px 0px -10% 0px' });

    items.forEach(function (item) { io.observe(item); });
  }

  wireSequentialFlow('.capstrip-list', '.capitem', '--cap-scale');
  wireSequentialFlow('.steps', '.step', '--proc-scale');
})();

// FormSubmit handles the POST + redirect natively via the form's action/_next
// fields — no fetch/AJAX needed here.
