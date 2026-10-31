var ExtensionPreprocessingJS = {
    run: a => {
        const meta = document.querySelector('meta[name="description"]') ||
            document.querySelector('meta[property="og:description"]');
        a.completionFunction({
            url: document.URL,
            title: document.title,
            selection: String(window.getSelection()),
            description: meta ? meta.getAttribute('content') : null
        });
    },
    finalize: () => {}
};
