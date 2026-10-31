var ExtensionPreprocessingJS = {
    run: a => a.completionFunction({
        url: document.URL,
        title: document.title,
        selection: String(window.getSelection())
    }),
    finalize: () => {}
};
