/* Licensed to the public under the Apache License 2.0. */

'use strict';
'require baseclass';

return baseclass.extend({
	title: _('MCU battery'),

	rrdargs(graph, host, plugin, plugin_instance, dtype) {
		const rv = [];
		const types = graph.dataTypes(host, plugin, plugin_instance);

		if (types.includes('temperature')) {
			rv.push({
				title: '%H: Battery temperature',
				vlabel: '\u00b0C',
				alt_autoscale: true,
				number_format: '%3.1lf\u00b0C',
				data: {
					instances: {
						temperature: [ 'battery' ]
					},
					options: {
						temperature_battery: {
							title: 'Temperature',
							color: 'e00000',
							noarea: true
						}
					}
				}
			});
		}

		if (types.includes('percent')) {
			const instances = {};

			if (types.includes('gauge'))
				instances.gauge = [ 'charging' ];

			instances.percent = [ 'charge' ];

			rv.push({
				title: '%H: Battery charge',
				vlabel: 'Percent',
				y_min: '0',
				y_max: '100',
				number_format: '%3.0lf%%',
				data: {
					instances: instances,
					options: {
						gauge_charging: {
							title: 'Charging',
							color: 'b8e8ff',
							transform_rpn: '100,*'
						},
						percent_charge: {
							title: 'Charge',
							color: '00a000',
							noarea: true,
							overlay: true,
							weight: 2
						}
					}
				}
			});
		}

		if (types.includes('gauge')) {
			rv.push({
				title: '%H: Battery flags',
				vlabel: 'State',
				y_min: '0',
				y_max: '1',
				number_format: '%1.0lf',
				data: {
					instances: {
						gauge: [ 'fastcharge', 'abnormal' ]
					},
					options: {
						gauge_fastcharge: {
							title: 'Fast charge',
							color: 'ff9000',
							noarea: true,
							overlay: true
						},
						gauge_abnormal: {
							title: 'Abnormal',
							color: 'ff0000',
							noarea: true,
							overlay: true
						}
					}
				}
			});
		}

		return rv;
	}
});
