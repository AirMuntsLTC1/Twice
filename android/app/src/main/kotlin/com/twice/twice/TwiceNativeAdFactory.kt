package com.twice.twice

import android.content.Context
import android.view.LayoutInflater
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.TextView
import com.google.android.gms.ads.nativead.MediaView
import com.google.android.gms.ads.nativead.NativeAd
import com.google.android.gms.ads.nativead.NativeAdView
import io.flutter.plugins.googlemobileads.GoogleMobileAdsPlugin

/**
 * Renders an AdMob native ad as an Instagram-style sponsored post.
 * Registered in MainActivity under the id "twiceInstagramAd".
 */
class TwiceNativeAdFactory(private val context: Context) :
    GoogleMobileAdsPlugin.NativeAdFactory {

    override fun createNativeAd(
        nativeAd: NativeAd,
        customOptions: MutableMap<String, Any>?
    ): NativeAdView {
        val adView = LayoutInflater.from(context)
            .inflate(R.layout.twice_native_ad, null) as NativeAdView

        val icon = adView.findViewById<ImageView>(R.id.twice_ad_icon)
        val headline = adView.findViewById<TextView>(R.id.twice_ad_headline)
        val sponsored = adView.findViewById<TextView>(R.id.twice_ad_sponsored)
        val media = adView.findViewById<MediaView>(R.id.twice_ad_media)
        val cta = adView.findViewById<Button>(R.id.twice_ad_cta)
        val body = adView.findViewById<TextView>(R.id.twice_ad_body)

        // Register every asset view BEFORE setNativeAd (required by AdMob).
        adView.iconView = icon
        adView.headlineView = headline
        adView.mediaView = media
        adView.callToActionView = cta
        adView.bodyView = body

        headline.text = nativeAd.headline ?: ""

        // "Sponsored" label is always visible (policy). Advertiser is appended.
        val advertiser = nativeAd.advertiser
        if (!advertiser.isNullOrEmpty()) {
            sponsored.text = "Sponsored · $advertiser"
            adView.advertiserView = sponsored
        } else {
            sponsored.text = "Sponsored"
        }

        val iconDrawable = nativeAd.icon?.drawable
        if (iconDrawable != null) {
            icon.setImageDrawable(iconDrawable)
            icon.clipToOutline = true
            icon.visibility = View.VISIBLE
        } else {
            icon.visibility = View.GONE
        }

        media.setImageScaleType(ImageView.ScaleType.CENTER_CROP)

        val callToAction = nativeAd.callToAction
        if (callToAction.isNullOrEmpty()) {
            cta.visibility = View.GONE
        } else {
            cta.text = callToAction
            cta.visibility = View.VISIBLE
        }

        val bodyText = nativeAd.body
        if (bodyText.isNullOrEmpty()) {
            body.visibility = View.GONE
        } else {
            body.text = bodyText
            body.visibility = View.VISIBLE
        }

        adView.setNativeAd(nativeAd)
        return adView
    }
}
