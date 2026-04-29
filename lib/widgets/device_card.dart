import 'package:flutter/material.dart';
import '../../models/device.dart';

class DeviceCard extends StatelessWidget {
  final Device device;
  final VoidCallback onToggle;

  const DeviceCard({
    super.key,
    required this.device,
    required this.onToggle,
  });

  IconData _getIconForType(DeviceType type) {
    switch (type) {
      case DeviceType.light: return Icons.lightbulb_outline;
      case DeviceType.fan: return Icons.mode_fan_off;
      case DeviceType.ac: return Icons.ac_unit;
      case DeviceType.sensor: return Icons.sensors;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: device.isOn 
          ? Theme.of(context).colorScheme.primaryContainer 
          : Theme.of(context).cardTheme.color,
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(
                    _getIconForType(device.type),
                    color: device.isOn 
                        ? Theme.of(context).colorScheme.primary 
                        : Colors.grey,
                  ),
                  Switch(
                    value: device.isOn,
                    onChanged: (val) => onToggle(),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                device.name,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 4),
              Text(
                device.isOn ? 'ON' : 'OFF',
                style: TextStyle(
                  color: device.isOn 
                      ? Theme.of(context).colorScheme.primary 
                      : Colors.grey,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
