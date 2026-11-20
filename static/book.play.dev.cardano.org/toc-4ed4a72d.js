// Populate the sidebar
//
// This is a script, and not included directly in the page, to control the total size of the book.
// The TOC contains an entry for each page, so if each page includes a copy of the TOC,
// the total size of the page becomes O(n**2).
class MDBookSidebarScrollbox extends HTMLElement {
    constructor() {
        super();
    }
    connectedCallback() {
        this.innerHTML = '<ol class="chapter"><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="README-book.html">Cardano</a></span></li><li class="chapter-item expanded "><li class="part-title">Reference</li></li><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="environments.html"><strong aria-hidden="true">1.</strong> Environments</a></span><ol class="section"><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="env-preview.html"><strong aria-hidden="true">1.1.</strong> Preview</a></span></li><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="env-preprod.html"><strong aria-hidden="true">1.2.</strong> Pre-production</a></span></li><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="env-mainnet.html"><strong aria-hidden="true">1.3.</strong> Mainnet</a></span></li></ol><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="advanced.html"><strong aria-hidden="true">2.</strong> Advanced</a></span><ol class="section"><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="adv-preview.html"><strong aria-hidden="true">2.1.</strong> Preview pre-release</a></span></li><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="adv-preprod.html"><strong aria-hidden="true">2.2.</strong> Pre-production pre-release</a></span></li><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="adv-dijkstra.html"><strong aria-hidden="true">2.3.</strong> Dijkstra Testnet</a></span></li><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="adv-musashi.html"><strong aria-hidden="true">2.4.</strong> MusashiNet prototype</a></span></li></ol><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="cost-model.html"><strong aria-hidden="true">3.</strong> Cost Model</a></span><ol class="section"><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="cm-2024-07-30.html"><strong aria-hidden="true">3.1.</strong> 2024-07-30</a></span></li><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="cm-2023-02-14.html"><strong aria-hidden="true">3.2.</strong> 2023-02-14</a></span></li><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="cm-2022-11-05.html"><strong aria-hidden="true">3.3.</strong> 2022-11-05</a></span></li><li class="chapter-item expanded "><span class="chapter-link-wrapper"><a href="cm-2022-07-01.html"><strong aria-hidden="true">3.4.</strong> 2022-07-01</a></span></li></ol></li></ol>';
        // Set the current, active page, and reveal it if it's hidden
        let current_page = document.location.href.toString().split('#')[0].split('?')[0];
        if (current_page.endsWith('/')) {
            current_page += 'index.html';
        }
        const links = Array.prototype.slice.call(this.querySelectorAll('a'));
        const l = links.length;
        for (let i = 0; i < l; ++i) {
            const link = links[i];
            const href = link.getAttribute('href');
            if (href && !href.startsWith('#') && !/^(?:[a-z+]+:)?\/\//.test(href)) {
                link.href = path_to_root + href;
            }
            // The 'index' page is supposed to alias the first chapter in the book.
            if (link.href === current_page
                || i === 0
                && path_to_root === ''
                && current_page.endsWith('/index.html')) {
                link.classList.add('active');
                let parent = link.parentElement;
                while (parent) {
                    if (parent.tagName === 'LI' && parent.classList.contains('chapter-item')) {
                        parent.classList.add('expanded');
                    }
                    parent = parent.parentElement;
                }
            }
        }
        // Track and set sidebar scroll position
        this.addEventListener('click', e => {
            if (e.target.tagName === 'A') {
                const clientRect = e.target.getBoundingClientRect();
                const sidebarRect = this.getBoundingClientRect();
                sessionStorage.setItem('sidebar-scroll-offset', clientRect.top - sidebarRect.top);
            }
        }, { passive: true });
        const sidebarScrollOffset = sessionStorage.getItem('sidebar-scroll-offset');
        sessionStorage.removeItem('sidebar-scroll-offset');
        if (sidebarScrollOffset !== null) {
            // preserve sidebar scroll position when navigating via links within sidebar
            const activeSection = this.querySelector('.active');
            if (activeSection) {
                const clientRect = activeSection.getBoundingClientRect();
                const sidebarRect = this.getBoundingClientRect();
                const currentOffset = clientRect.top - sidebarRect.top;
                this.scrollTop += currentOffset - parseFloat(sidebarScrollOffset);
            }
        } else {
            // scroll sidebar to current active section when navigating via
            // 'next/previous chapter' buttons
            const activeSection = document.querySelector('#mdbook-sidebar .active');
            if (activeSection) {
                activeSection.scrollIntoView({ block: 'center' });
            }
        }
        // Toggle buttons
        const sidebarAnchorToggles = document.querySelectorAll('.chapter-fold-toggle');
        function toggleSection(ev) {
            ev.currentTarget.parentElement.parentElement.classList.toggle('expanded');
        }
        Array.from(sidebarAnchorToggles).forEach(el => {
            el.addEventListener('click', toggleSection);
        });
    }
}
window.customElements.define('mdbook-sidebar-scrollbox', MDBookSidebarScrollbox);

