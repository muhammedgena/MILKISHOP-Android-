package com.milki.shop

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

class MainActivity : Activity() {
    companion object {
        private const val HOME_URL = "https://milki-marketplace-admin.vercel.app/"
        private const val TRUSTED_HOST = "milki-marketplace-admin.vercel.app"
        private const val FILE_CHOOSER_REQUEST_CODE = 1001
    }

    private lateinit var webView: WebView
    private lateinit var progressBar: ProgressBar
    private lateinit var errorPanel: LinearLayout
    private var mainFrameFailed = false
    private var uploadCallback: ValueCallback<Array<Uri>>? = null

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Color.rgb(7, 88, 61)
        window.navigationBarColor = Color.rgb(7, 88, 61)

        val root = FrameLayout(this).apply { setBackgroundColor(Color.WHITE) }
        webView = WebView(this).apply {
            setBackgroundColor(Color.WHITE)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.loadsImagesAutomatically = true
            settings.javaScriptCanOpenWindowsAutomatically = false
            settings.allowFileAccess = false
            // Required only for Android's user-selected content:// upload URIs.
            settings.allowContentAccess = true
            settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) settings.safeBrowsingEnabled = true
            CookieManager.getInstance().setAcceptCookie(true)
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
            webViewClient = createWebViewClient()
            webChromeClient = object : WebChromeClient() {
                override fun onProgressChanged(view: WebView?, newProgress: Int) {
                    progressBar.progress = newProgress
                    progressBar.visibility =
                        if (newProgress in 1..99 && !mainFrameFailed) View.VISIBLE else View.GONE
                }

                override fun onShowFileChooser(
                    view: WebView?,
                    filePathCallback: ValueCallback<Array<Uri>>?,
                    fileChooserParams: FileChooserParams?
                ): Boolean {
                    if (filePathCallback == null || fileChooserParams == null) return false
                    uploadCallback?.onReceiveValue(null)
                    uploadCallback = filePathCallback
                    return try {
                        startActivityForResult(
                            fileChooserParams.createIntent(),
                            FILE_CHOOSER_REQUEST_CODE
                        )
                        true
                    } catch (_: ActivityNotFoundException) {
                        uploadCallback = null
                        filePathCallback.onReceiveValue(null)
                        false
                    }
                }
            }
        }

        progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = false
            max = 100
            progress = 0
        }
        errorPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(28), dp(24), dp(28), dp(24))
            setBackgroundColor(Color.WHITE)
            visibility = View.GONE
        }
        val title = TextView(this).apply {
            text = "MILKISHOP"
            setTextColor(Color.rgb(7, 88, 61))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
            setTypeface(Typeface.DEFAULT, Typeface.BOLD)
            gravity = Gravity.CENTER
        }
        val message = TextView(this).apply {
            text = "We couldn't connect to MILKISHOP. Please check your internet connection and try again."
            setTextColor(Color.rgb(55, 65, 81))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            gravity = Gravity.CENTER
            setPadding(0, dp(14), 0, dp(18))
        }
        val retryButton = Button(this).apply {
            text = "Try again"
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.rgb(7, 88, 61))
            setOnClickListener { loadHome() }
        }
        errorPanel.addView(title, LinearLayout.LayoutParams(-1, -2))
        errorPanel.addView(message, LinearLayout.LayoutParams(-1, -2))
        errorPanel.addView(retryButton, LinearLayout.LayoutParams(-1, -2))
        root.addView(webView, FrameLayout.LayoutParams(-1, -1))
        root.addView(progressBar, FrameLayout.LayoutParams(-1, dp(3), Gravity.TOP))
        root.addView(errorPanel, FrameLayout.LayoutParams(-1, -1))
        setContentView(root)

        if (savedInstanceState == null || webView.restoreState(savedInstanceState) == null) loadHome()
    }

    private fun createWebViewClient() = object : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
            val uri = request?.url ?: return true
            if (uri.scheme.equals("https", true) && uri.host.equals(TRUSTED_HOST, true)) return false
            if (uri.scheme.equals("https", true) || uri.scheme.equals("http", true) ||
                uri.scheme.equals("mailto", true) || uri.scheme.equals("tel", true)) {
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, uri))
                } catch (_: ActivityNotFoundException) { }
            }
            return true
        }

        override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
            mainFrameFailed = false
            errorPanel.visibility = View.GONE
            progressBar.visibility = View.VISIBLE
        }

        override fun onPageFinished(view: WebView?, url: String?) {
            if (!mainFrameFailed) {
                progressBar.visibility = View.GONE
                errorPanel.visibility = View.GONE
            }
        }

        override fun onReceivedError(
            view: WebView?,
            request: WebResourceRequest?,
            error: android.webkit.WebResourceError?
        ) {
            super.onReceivedError(view, request, error)
            if (request?.isForMainFrame == true) showConnectionError()
        }

        override fun onReceivedHttpError(
            view: WebView?,
            request: WebResourceRequest?,
            errorResponse: android.webkit.WebResourceResponse?
        ) {
            super.onReceivedHttpError(view, request, errorResponse)
            if (request?.isForMainFrame == true && (errorResponse?.statusCode ?: 200) >= 400) {
                showConnectionError()
            }
        }

        override fun onReceivedSslError(
            view: WebView?,
            handler: SslErrorHandler?,
            error: SslError?
        ) {
            handler?.cancel()
            showConnectionError()
        }
    }

    private fun loadHome() {
        mainFrameFailed = false
        errorPanel.visibility = View.GONE
        progressBar.visibility = View.VISIBLE
        try {
            val html = assets.open("index.html").bufferedReader(Charsets.UTF_8).use { it.readText() }
            // Retain the trusted HTTPS origin for Supabase Auth, Storage and API CORS.
            webView.loadDataWithBaseURL(HOME_URL, html, "text/html", "UTF-8", HOME_URL)
        } catch (_: Exception) {
            showConnectionError()
        }
    }

    private fun showConnectionError() {
        mainFrameFailed = true
        progressBar.visibility = View.GONE
        errorPanel.visibility = View.VISIBLE
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == FILE_CHOOSER_REQUEST_CODE) {
            val callback = uploadCallback
            uploadCallback = null
            callback?.onReceiveValue(
                if (resultCode == Activity.RESULT_OK && data != null) {
                    WebChromeClient.FileChooserParams.parseResult(resultCode, data)
                } else null
            )
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        if (::webView.isInitialized) webView.saveState(outState)
        super.onSaveInstanceState(outState)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (::webView.isInitialized && webView.canGoBack()) webView.goBack()
        else super.onBackPressed()
    }

    override fun onDestroy() {
        uploadCallback?.onReceiveValue(null)
        uploadCallback = null
        if (::webView.isInitialized) {
            webView.stopLoading()
            webView.loadUrl("about:blank")
            webView.removeAllViews()
            webView.destroy()
        }
        super.onDestroy()
    }
}
