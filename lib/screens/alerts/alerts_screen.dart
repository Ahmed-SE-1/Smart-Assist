import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timeago/timeago.dart' as timeago;
import '../../providers/alerts_provider.dart';
import '../../models/smart_alert.dart';

class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  int _selectedTabIndex = 0;
  final List<String> _tabs = ['All', 'Critical', 'Warnings', 'System'];

  @override
  Widget build(BuildContext context) {
    final allAlerts = ref.watch(alertsProvider);
    
    // Filter alerts based on selected tab
    final List<SmartAlert> filteredAlerts = allAlerts.where((alert) {
      if (_selectedTabIndex == 0) return true; // All
      if (_selectedTabIndex == 1) return alert.severity == AlertSeverity.critical; // Critical
      if (_selectedTabIndex == 2) return alert.severity == AlertSeverity.warning; // Warnings
      return alert.severity == AlertSeverity.info; // System/Info
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FC),
      appBar: AppBar(
        title: const Text('Alerts & Logs'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
        ],
      ),
      body: Column(
        children: [
          // Segmented Control (Tabs)
          Container(
            height: 40,
            margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _tabs.length,
              itemBuilder: (context, index) {
                final isSelected = _selectedTabIndex == index;
                return GestureDetector(
                  onTap: () => setState(() => _selectedTabIndex = index),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    margin: const EdgeInsets.only(right: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected ? Theme.of(context).colorScheme.primary : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: isSelected ? Colors.transparent : Colors.grey.shade300),
                    ),
                    child: Text(
                      _tabs[index],
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.grey.shade600,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // Alert List
          Expanded(
            child: filteredAlerts.isEmpty 
              ? Center(
                  child: Text('No alerts found.', style: TextStyle(color: Colors.grey.shade500)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  itemCount: filteredAlerts.length,
                  itemBuilder: (context, index) {
                    final alert = filteredAlerts[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 5)),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: _getAlertColor(alert.severity).withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(_getAlertIcon(alert.severity), color: _getAlertColor(alert.severity)),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(alert.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF2D3436))),
                                const SizedBox(height: 4),
                                Text(alert.description, style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                              ],
                            ),
                          ),
                          Text(timeago.format(alert.timestamp, locale: 'en_short'), style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
                        ],
                      ),
                    );
                  },
                ),
          ),
        ],
      ),
    );
  }

  Color _getAlertColor(AlertSeverity severity) {
    switch (severity) {
      case AlertSeverity.info: return Colors.blue;
      case AlertSeverity.warning: return Colors.orange;
      case AlertSeverity.critical: return Colors.red;
    }
  }

  IconData _getAlertIcon(AlertSeverity severity) {
    switch (severity) {
      case AlertSeverity.info: return Icons.info_outline;
      case AlertSeverity.warning: return Icons.warning_amber_rounded;
      case AlertSeverity.critical: return Icons.error_outline;
    }
  }
}
