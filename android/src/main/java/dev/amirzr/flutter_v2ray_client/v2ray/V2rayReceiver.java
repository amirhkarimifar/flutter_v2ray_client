package dev.amirzr.flutter_v2ray_client.v2ray;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

import java.util.ArrayList;

import io.flutter.plugin.common.EventChannel;

public class V2rayReceiver extends BroadcastReceiver {
    public static EventChannel.EventSink vpnStatusSink;

    @Override
    public void onReceive(Context context, Intent intent) {
        try {
            // Check if vpnStatusSink is available and not null
            if (vpnStatusSink == null) {
                Log.w("V2rayReceiver", "vpnStatusSink is null, skipping broadcast");
                return;
            }
            
            // Check if intent has extras to prevent null pointer exceptions
            if (intent == null || intent.getExtras() == null) {
                Log.w("V2rayReceiver", "Intent or extras is null, skipping broadcast");
                return;
            }
            
            ArrayList<String> list = new ArrayList<>();
            list.add(intent.getExtras().getString("DURATION"));
            list.add(String.valueOf(intent.getLongExtra("UPLOAD_SPEED", 0)));
            list.add(String.valueOf(intent.getLongExtra("DOWNLOAD_SPEED", 0)));
            list.add(String.valueOf(intent.getLongExtra("UPLOAD_TRAFFIC", 0)));
            list.add(String.valueOf(intent.getLongExtra("DOWNLOAD_TRAFFIC", 0)));
            
            // Safely handle STATE serializable to prevent crashes
            Object state = intent.getExtras().getSerializable("STATE");
            if (state != null) {
                String stateString = state.toString();
                if (stateString.length() > 6) {
                    list.add(stateString.substring(6));
                } else {
                    list.add(stateString);
                }
            } else {
                list.add("UNKNOWN");
            }
            
            vpnStatusSink.success(list);
        } catch (Exception e) {
            Log.e("V2rayReceiver", "onReceive failed", e);
        }
    }

}
